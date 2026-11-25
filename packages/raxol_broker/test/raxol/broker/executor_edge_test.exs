defmodule Raxol.Broker.ExecutorEdgeTest do
  @moduledoc """
  Executor edge cases (see `Raxol.Broker.Test.ExecutorCase`): hostile caller
  data and messages, port loss mid-pipeline, queue draining, and tool
  schemas that drifted from the capture.
  """
  use Raxol.Broker.Test.ExecutorCase, async: true

  alias Raxol.Broker.{Executor, Journal}
  alias Raxol.Broker.Executor.Place
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.{ExecutorCase, Hostile}
  alias Raxol.Broker.Tools.Catalog

  @t0 ExecutorCase.t0()

  describe "caller data, port loss and draining" do
    test "a struct in caller data never runs: refused before any call", ctx do
      executor = start_executor!(ctx)
      before = records(ctx.path)
      hostile = %{context() | quotes: Hostile.new(), positions: Hostile.new()}
      intent = limit("hostile")

      assert {:error, {:invalid_context, _}} = Executor.run(executor, intent, hostile)
      # Straight to the server, past the client-side check.
      assert {:error, {:invalid_context, _}} =
               GenServer.call(executor, {:run, intent, hostile})

      assert {:error, {:invalid_intent, _}} =
               GenServer.call(executor, {:run, Hostile.new(), context()})

      assert {:error, {:invalid_intent, _}} =
               GenServer.call(executor, {:run, %{intent | params: Hostile.new()}, context()})

      assert {:error, :unknown_request} = GenServer.call(executor, Hostile.new())

      refute_received {:hostile, _callback}
      assert records(ctx.path) == before
      assert Fake.calls(ctx.server) == []
      assert Process.alive?(executor)
      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
    end

    test "a port lost between review and place closes the group unplaced", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      intent = limit("port-gone")
      run = Task.async(fn -> Executor.run(executor, intent, context()) end)
      assert_receive {:reviewing, hook}, 5_000

      # Hold the review task with the answer in its mailbox, then lose the
      # client and let the executor handle that EXIT before the result.
      %{busy: %{pid: review}} = :sys.get_state(executor)
      true = :erlang.suspend_process(review)
      hook_ref = Process.monitor(hook)
      send(hook, :go)
      assert_receive {:DOWN, ^hook_ref, :process, ^hook, _}, 5_000
      _ = :sys.get_state(client)
      stop_and_wait(client)
      assert %{port: nil} = :sys.get_state(executor)
      true = :erlang.resume_process(review)

      assert Task.await(run) == {:error, :port_not_ready}
      [gid] = groups_for(ctx.path, "port-gone")
      refute "placing" in types(ctx.path, gid)
      assert List.last(group(ctx.path, gid))["reason"] == "port_not_ready"
      assert Fake.calls(ctx.server, "place_") == []

      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      assert :ok = Executor.await_port(executor, 5_000)
      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a client that dies while connecting leaves the executor up", ctx do
      {:ok, dns} = Agent.start_link(fn -> :raise end)
      test_pid = self()
      good = Fake.session(ctx.server)[:resolver]

      session =
        Keyword.put(Fake.session(ctx.server), :resolver, fn host, family ->
          case Agent.get(dns, & &1) do
            :raise ->
              send(test_pid, :resolving)
              raise "resolver blew up"

            :ok ->
              good.(host, family)
          end
        end)

      {:ok, executor} =
        Executor.start_link(executor_opts(ctx, session: session, reconnect_ms: 10))

      assert_receive :resolving, 5_000
      assert %{connect: %Task{}, port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)
      stop_and_wait(client)
      # Handled the EXIT (a reconnect may already be under way) and still up.
      assert %{port_status: status} = :sys.get_state(executor)
      assert status != :ready

      Agent.update(dns, fn _ -> :ok end)
      assert :ok = Executor.await_port(executor, 5_000)
      assert Process.alive?(executor)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("reborn"), context())
    end

    test "await_port refuses a timeout past the timer limit and stays up", ctx do
      session =
        Keyword.put(Fake.session(ctx.server), :resolver, fn _host, _family ->
          {:error, :nxdomain}
        end)

      {:ok, executor} = Executor.start_link(executor_opts(ctx, session: session))
      huge = 10_000_000_000

      assert Executor.await_port(executor, huge) ==
               {:error, {:invalid_timeout, :await_port, huge}}

      assert Executor.await_port(executor, 0) == {:error, :port_not_ready}
      assert Process.alive?(executor)
    end

    test "approvals queued behind a review drain one per callback, in order", ctx do
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, g1, _} = Executor.run(executor, limit("drain-1"), context())
      {:ask, g2, _} = Executor.run(executor, limit("drain-2"), context())
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      held = Task.async(fn -> Executor.run(executor, limit("drain-held"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      first = Task.async(fn -> Executor.approve(executor, g1, "droo") end)
      wait_queued(executor, 1)
      second = Task.async(fn -> Executor.approve(executor, g2, "droo") end)
      wait_queued(executor, 2)

      :ok =
        :sys.install(
          executor,
          {fn
             n, {:in, :drain}, _name ->
               send(test_pid, {:drain, n})
               n + 1

             n, _event, _name ->
               n
           end, 0}
        )

      send(hook, :go)
      assert {:ask, _gid, _} = Task.await(held)
      assert {:ok, %{group_id: ^g1, status: :placed}} = Task.await(first)
      assert {:ok, %{group_id: ^g2, status: :placed}} = Task.await(second)

      # One :drain dispatched the first approval, a second the next.
      assert_receive {:drain, 0}
      assert_receive {:drain, 1}

      refs = for {"place_" <> _, args} <- Fake.calls(ctx.server), do: args["ref_id"]
      assert refs == [Place.ref_id("drain-1"), Place.ref_id("drain-2")]
    end

    test "a stalled journal writer stops the journal and then the executor", ctx do
      restart_journal!(ctx, write_deadline: 50)
      executor = start_executor!(ctx)
      ref = Process.monitor(executor)

      :ok = :sys.suspend(writer(ctx.path))

      assert {:error, {:journal_down, _}} =
               Executor.run(executor, limit("stalled"), context())

      assert_receive {:DOWN, ^ref, :process, ^executor, {:journal_down, {:writer_stalled, 50}}},
                     5_000

      assert Fake.calls(ctx.server) == []
    end
  end

  describe "hostile terms and stale messages" do
    test "a hostile message is ignored without running its protocols", ctx do
      executor = start_executor!(ctx)
      GenServer.cast(executor, Hostile.new())
      GenServer.cast(executor, {:unexpected, Hostile.new()})
      before = records(ctx.path)

      send(executor, Hostile.new())
      send(executor, {:unexpected, Hostile.new()})
      send(executor, {Hostile.new(), :tag})
      send(executor, [Hostile.new()])
      _ = :sys.get_state(executor)

      refute_received {:hostile, _callback}
      assert Process.alive?(executor)
      assert records(ctx.path) == before
      assert Fake.calls(ctx.server) == []
    end

    test "a port client stopped with a struct reason runs no protocol and reconnects", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)

      stop_and_wait(client, {:shutdown, Hostile.new()})
      _ = :sys.get_state(executor)

      refute_received {:hostile, _callback}
      assert :ok = Executor.await_port(executor, 5_000)
      assert %{port: {PortMCP, %{pid: new_client}}} = :sys.get_state(executor)
      assert new_client != client
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("struct-exit"), context())
    end

    test "a clock DateTime in another calendar is a context error; nothing opens", ctx do
      {:ok, clocks} = Agent.start_link(fn -> fn -> @t0 end end)
      executor = start_executor!(ctx, clock: fn -> Agent.get(clocks, & &1).() end)

      bad = [
        %{@t0 | calendar: __MODULE__.NotACalendar},
        %{@t0 | utc_offset: 3_600},
        %{@t0 | month: 13},
        %{@t0 | microsecond: {0, 9}}
      ]

      for now <- bad do
        Agent.update(clocks, fn _ -> fn -> now end end)

        assert {:error, {:context, {:invalid_clock, _}}} =
                 Executor.run(executor, limit("odd-calendar"), context())
      end

      assert Process.alive?(executor)
      assert groups_for(ctx.path, "odd-calendar") == []
      assert Fake.calls(ctx.server) == []
    end

    test "a stale :drain during a review is ignored; the queued run completes", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      held = Task.async(fn -> Executor.run(executor, limit("stale-held"), context()) end)
      assert_receive {:reviewing, hook}, 5_000
      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)

      # Suspended, the executor takes the queued call and the stale :drain
      # in this order once resumed, while the held review keeps it busy.
      :ok = :sys.suspend(executor)
      ref = Process.monitor(executor)
      send(executor, {:"$gen_call", {self(), ref}, {:run, limit("stale-queued"), context()}})
      send(executor, :drain)
      :ok = :sys.resume(executor)

      assert %{busy: %{}, queue: queue} = :sys.get_state(executor)
      assert :queue.len(queue) == 1
      assert Process.alive?(executor)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(held)
      assert_receive {^ref, {:ok, %{status: :placed}}}, 5_000
      refute_received {:DOWN, ^ref, :process, _, _}

      assert Fake.calls(ctx.server, "place_") == [
               "place_equity_order",
               "place_equity_order"
             ]
    end

    test "a port gone before the place call is :failed, not_sent; a re-run places", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      intent = limit("noproc")
      run = Task.async(fn -> Executor.run(executor, intent, context()) end)
      assert_receive {:reviewing, hook}, 5_000

      # The review result reaches the executor's mailbox while it is
      # suspended; the client then dies, so its EXIT queues behind the
      # result and the place call meets a dead pid.
      %{busy: %{pid: review}} = :sys.get_state(executor)
      :ok = :sys.suspend(executor)
      review_ref = Process.monitor(review)
      send(hook, :go)
      assert_receive {:DOWN, ^review_ref, :process, ^review, _}, 5_000
      client_ref = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^client_ref, :process, ^client, _}, 5_000
      :ok = :sys.resume(executor)

      assert {:ok, %{status: :failed, response: %{"not_sent" => true}, journaled: true}} =
               Task.await(run)

      assert Fake.calls(ctx.server, "place_") == []

      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      assert :ok = Executor.await_port(executor, 5_000)
      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end

  describe "tool catalog" do
    defp served(name, change) do
      Catalog.recorded_tools() |> Enum.find(&(&1["name"] == name)) |> change.()
    end

    defp add_property(tool),
      do: put_in(tool, ["inputSchema", "properties", "extra"], %{"type" => "string"})

    test "a place tool whose schema changed since the capture is refused; nothing is sent",
         ctx do
      fake = Fake.start(tools: [served("place_equity_order", &add_property/1)])
      executor = start_executor!(ctx, session: Fake.session(fake))

      assert {:error, {:tool_refused, "place_equity_order", :unknown}} =
               Executor.run(executor, limit("drifted-place"), context())

      assert Fake.calls(fake, "review_") == ["review_equity_order"]
      assert Fake.calls(fake, "place_") == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
    end

    test "a review tool whose schema changed is refused before the review call", ctx do
      fake = Fake.start(tools: [served("review_equity_order", &add_property/1)])
      executor = start_executor!(ctx, session: Fake.session(fake))

      assert {:error, {:tool_refused, "review_equity_order", :unknown}} =
               Executor.run(executor, limit("drifted-review"), context())

      assert Fake.calls(fake) == []
    end

    test "a served place tool the capture lacks is :unknown and logged at :error", ctx do
      foo = %{"name" => "place_foo_order", "inputSchema" => %{"type" => "object"}}
      fake = Fake.start(tools: [foo])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_executor!(ctx, session: Fake.session(fake))
        end)

      assert Catalog.classify("place_foo_order") == :unknown
      assert log =~ ~r/\[error\].*place_foo_order is not in the capture/
    end
  end
end

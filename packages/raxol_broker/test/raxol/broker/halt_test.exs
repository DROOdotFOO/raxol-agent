defmodule Raxol.Broker.HaltTest do
  @moduledoc """
  The kill switch and the dead-man switch against a real executor, journal
  and strategy supervisor on the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Executor, Halt, Heartbeat, Intent, Journal, Mode, Strategy}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  defp broker!(fake_opts \\ [], executor_opts \\ []) do
    ctx = Broker.journal!()
    fake = Fake.start(Keyword.merge([quotes: %{"F" => "9.80", "AAPL" => "125"}], fake_opts))
    sup = :"strategies_#{System.unique_integer([:positive])}"
    executor = Broker.executor!(ctx.journal, fake, Keyword.put(executor_opts, :strategies, sup))

    start_supervised!(
      {Strategy.Supervisor,
       name: sup, journal: ctx.journal, executor: executor, clock: &Broker.t0/0}
    )

    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
    :ok = Strategy.Supervisor.add(spec, journal: ctx.journal, supervisor: sup)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    Map.merge(ctx, %{fake: fake, executor: executor, sup: sup})
  end

  defp place!(ctx, id) do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d("1"), d("125"), provenance: :human, id: id)
    {:ok, %{status: status}} = Executor.run(ctx.executor, intent, %Context{})
    status
  end

  defp kill!(ctx, bound \\ 5_000) do
    {:ok, summary} =
      Halt.kill(
        journal: ctx.journal,
        executor: ctx.executor,
        strategies: ctx.sup,
        bound: bound,
        trigger: "test"
      )

    summary
  end

  defp types(path), do: path |> Broker.records() |> Enum.map(& &1["type"])

  defp wait_queued(executor) do
    if :queue.is_empty(:sys.get_state(executor).queue), do: wait_queued(executor)
  end

  defp hold_call(fake, tool, held?) do
    test = self()

    Fake.on_call(fake, tool, fn args ->
      if held?.(args) do
        send(test, {:held, self()})
        receive do: (:release -> :answer)
      else
        :answer
      end
    end)
  end

  defp release_call(hook) do
    ref = Process.monitor(hook)
    send(hook, :release)
    assert_receive {:DOWN, ^ref, :process, ^hook, _}, 5_000
  end

  defp intent(id) do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d("1"), d("125"), provenance: :human, id: id)
    intent
  end

  describe "kill/1" do
    test "three open orders: three cancels, no running strategy, disarmed, in journal order" do
      ctx = broker!()
      for id <- ~w(k1 k2 k3), do: :placed = place!(ctx, id)
      before = length(Broker.records(ctx.path))

      summary = kill!(ctx)

      assert Fake.calls(ctx.fake, "cancel_") == List.duplicate("cancel_equity_order", 3)
      assert Enum.all?(Fake.orders(ctx.fake), &(&1["state"] == "cancelled"))
      assert Strategy.Supervisor.running(ctx.sup) == []
      assert Mode.current(ctx.journal) == :disarmed
      assert {:ok, [_, _, _]} = summary.orders
      assert Enum.map(summary.results, & &1.outcome) == ~w(placed placed placed)

      after_kill = ctx.path |> types() |> Enum.drop(before)
      assert hd(after_kill) == "mode"
      assert List.last(after_kill) == "halt"
      assert Enum.count(after_kill, &(&1 == "order")) == 3

      halt = ctx.path |> Broker.records() |> List.last()
      assert %{"reason" => "kill", "trigger" => "test", "results" => [_, _, _]} = halt
    end

    test "a cancel that hangs: kill returns within the bound, two cancelled, one timeout" do
      ctx = broker!()
      for id <- ~w(t1 t2 t3), do: :placed = place!(ctx, id)
      [_, %{"order_id" => stuck}, _] = Fake.orders(ctx.fake)

      Fake.on_call(ctx.fake, "cancel_equity_order", fn args ->
        if args["order_id"] == stuck, do: :hang, else: :answer
      end)

      {micros, summary} = :timer.tc(fn -> kill!(ctx, 300) end)
      assert micros < 3_000_000

      outcomes = Map.new(summary.results, &{&1.id, &1.outcome})
      assert outcomes[stuck] == "unknown :timeout"
      assert outcomes |> Map.delete(stuck) |> Map.values() == ["placed", "placed"]

      orders = for %{"type" => "order"} = r <- Broker.records(ctx.path), do: r
      assert Enum.count(orders, &(&1["response"]["error"] == ":timeout")) == 1
    end

    for tool <- ~w(review_equity_order get_equity_quotes get_equity_positions get_portfolio) do
      @held_tool tool
      test "kill interrupts a held #{tool} before queued work" do
        ctx = broker!()
        :placed = place!(ctx, "existing-before-hold")
        [%{"order_id" => order_id}] = Fake.orders(ctx.fake)
        hold_call(ctx.fake, @held_tool, fn _args -> true end)

        run =
          Task.async(fn ->
            Executor.run(ctx.executor, intent("held-read"), %Context{})
          end)

        assert_receive {:held, hook}, 5_000
        %{busy: %{pid: worker}} = :sys.get_state(ctx.executor)
        worker_ref = Process.monitor(worker)

        queued =
          Task.async(fn -> Executor.run(ctx.executor, intent("queued-read"), %Context{}) end)

        wait_queued(ctx.executor)

        {micros, summary} = :timer.tc(fn -> kill!(ctx, 300) end)

        assert micros < 3_000_000
        assert [%{id: ^order_id, outcome: "placed"}] = summary.results
        assert [%{"state" => "cancelled"}] = Fake.orders(ctx.fake)
        assert Task.await(run) == {:error, :not_armed}
        assert Task.await(queued) == {:error, :not_armed}
        assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000
        assert Process.alive?(hook)

        # A fresh arm cannot revive the interrupted context or review.
        :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
        release_call(hook)
        assert :sys.get_state(ctx.executor).busy == nil
        assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
        assert Journal.open_groups(ctx.journal) == {:ok, []}
      end
    end

    test "kill interrupts reconciliation and cancels before its read is released" do
      ctx =
        broker!([faults: [{"place_equity_order", {:http, 503}}]], reconcile_min_age_ms: 0)

      :unknown = place!(ctx, "unresolved-before-hold")
      :placed = place!(ctx, "existing-before-reconcile")
      [%{"order_id" => order_id}] = Fake.orders(ctx.fake)
      hold_call(ctx.fake, "get_equity_orders", &is_nil(&1["state"]))

      reconcile = Task.async(fn -> Executor.reconcile(ctx.executor) end)
      assert_receive {:held, hook}, 5_000
      %{busy: %{pid: worker, stage: :reconcile}} = :sys.get_state(ctx.executor)
      worker_ref = Process.monitor(worker)

      queued =
        Task.async(fn -> Executor.run(ctx.executor, intent("queued-reconcile"), %Context{}) end)

      wait_queued(ctx.executor)

      {micros, summary} = :timer.tc(fn -> kill!(ctx, 300) end)

      assert micros < 3_000_000
      assert [%{id: ^order_id, outcome: "placed"}] = summary.results
      assert Task.await(reconcile) == {:error, :halted}
      assert Task.await(queued) == {:error, :not_armed}
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000
      assert Process.alive?(hook)

      release_call(hook)
      assert :sys.get_state(ctx.executor).busy == nil
      assert {:ok, [%{"intent_id" => "unresolved-before-hold"}]} = Journal.unresolved(ctx.journal)
      assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    end

    test "kill bypasses the held clock of an approval context refresh" do
      test = self()
      {:ok, gate} = Agent.start_link(fn -> false end)

      clock = fn ->
        if Agent.get(gate, & &1) do
          send(test, {:clock_held, self()})
          receive do: (:release -> Broker.t0())
        else
          Broker.t0()
        end
      end

      ctx = broker!([], clock: clock)
      :placed = place!(ctx, "existing-before-approval")
      Fake.warnings(ctx.fake, ["halted"])
      assert {:ask, group_id, _} = Executor.run(ctx.executor, intent("parked-clock"), %Context{})
      Agent.update(gate, fn _ -> true end)

      approve = Task.async(fn -> Executor.approve(ctx.executor, group_id, "owner") end)
      assert_receive {:clock_held, clock_task}, 5_000
      clock_ref = Process.monitor(clock_task)

      {micros, summary} = :timer.tc(fn -> kill!(ctx, 300) end)

      assert micros < 3_000_000
      assert [%{kind: :cancel, outcome: "placed"}] = summary.results
      assert Task.await(approve) == {:error, :not_armed}
      assert_receive {:DOWN, ^clock_ref, :process, ^clock_task, _}, 5_000
      assert Executor.parked(ctx.executor) == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    end

    test "pending trade approvals are declined through the executor" do
      ctx = broker!(trade_approvals: true)
      :pending_approval = place!(ctx, "proposal")

      summary = kill!(ctx)

      assert Fake.calls(ctx.fake, "decline_") == ["decline_trade_approval"]
      assert [%{"state" => "declined"}] = Fake.approvals(ctx.fake)
      assert [%{kind: :decline, outcome: "placed"}] = summary.results

      [intent] =
        for %{"type" => "intent", "intent" => %{"kind" => "decline"} = i} <-
              Broker.records(ctx.path),
            do: i

      assert "decline-" <> rest = intent["id"]
      assert String.starts_with?(rest, intent["order_id"] <> "-")
    end

    test "a second kill sends again a cancel the first could not confirm" do
      ctx = broker!()
      :placed = place!(ctx, "resend")
      [%{"order_id" => order_id}] = Fake.orders(ctx.fake)
      Fake.on_call(ctx.fake, "cancel_equity_order", fn _args -> :hang end)

      assert [%{outcome: "unknown :timeout"}] = kill!(ctx, 200).results
      Fake.on_call(ctx.fake, "cancel_equity_order", fn _args -> :answer end)

      assert [%{id: ^order_id, outcome: "placed"}] = kill!(ctx).results
      assert [%{"state" => "cancelled"}] = Fake.orders(ctx.fake)
    end

    test "every page of every open state is cancelled" do
      ctx = broker!(page_size: 1)
      for id <- ~w(p1 p2 p3), do: :placed = place!(ctx, id)

      summary = kill!(ctx)

      assert {:ok, [_, _, _]} = summary.orders
      assert Enum.all?(Fake.orders(ctx.fake), &(&1["state"] == "cancelled"))

      states =
        for {"get_equity_orders", %{"state" => s}} <- Fake.calls(ctx.fake), uniq: true, do: s

      assert states == ~w(new unconfirmed queued confirmed partially_filled)
    end

    test "a listing that fails is reported incomplete and the rest is still cancelled" do
      ctx = broker!(faults: [{"get_trade_approvals", {:http, 503}, 10}])
      :placed = place!(ctx, "partial")

      summary = kill!(ctx)

      assert {:error, {:incomplete, [], [{"get_trade_approvals", nil, _}]}} = summary.approvals
      assert [%{kind: :cancel, outcome: "placed"}] = summary.results
    end
  end

  describe "dead-man switch" do
    setup do
      ctx = broker!()
      {clock, time} = Broker.clock(0)

      heartbeat =
        start_supervised!(
          {Heartbeat,
           name: :"heartbeat_#{System.unique_integer([:positive])}",
           timeout: 1_000,
           journal: ctx.journal,
           strategies: ctx.sup,
           clock: clock,
           schedule: fn _ms -> :ok end}
        )

      Map.merge(ctx, %{heartbeat: heartbeat, time: time})
    end

    defp check!(heartbeat) do
      send(heartbeat, :check)
      Heartbeat.status(heartbeat)
    end

    defp runner_status(sup) do
      Enum.each(Strategy.Supervisor.running(sup), fn {pid, _} -> :sys.get_state(pid) end)
      sup |> Strategy.Supervisor.running() |> Enum.map(&elem(&1, 1).status)
    end

    test "silence past the timeout pauses strategies; a beat resumes them; both journaled", ctx do
      Agent.update(ctx.time, &(&1 + 999))
      assert %{paused: false} = check!(ctx.heartbeat)
      assert runner_status(ctx.sup) == [:running]

      Agent.update(ctx.time, &(&1 + 1))
      assert %{paused: true} = check!(ctx.heartbeat)
      assert runner_status(ctx.sup) == [:paused]
      assert Mode.current(ctx.journal) == :armed

      :ok = Heartbeat.beat(ctx.heartbeat, "test")
      assert runner_status(ctx.sup) == [:running]

      halts = for %{"type" => "halt"} = r <- Broker.records(ctx.path), do: r["reason"]
      assert halts == ["dead_man_pause", "dead_man_resume"]
    end

    test "a beat inside the timeout keeps strategies running", ctx do
      Agent.update(ctx.time, &(&1 + 900))
      :ok = Heartbeat.beat(ctx.heartbeat, "test")
      Agent.update(ctx.time, &(&1 + 900))
      assert %{paused: false} = check!(ctx.heartbeat)
      assert runner_status(ctx.sup) == [:running]
    end

    test "the pause outlives a runner restart and a heartbeat restart", ctx do
      Agent.update(ctx.time, &(&1 + 1_000))
      assert %{paused: true} = check!(ctx.heartbeat)
      assert Journal.pauses(ctx.journal) == {:ok, [:dead_man]}

      [{runner, _}] = Strategy.Supervisor.running(ctx.sup)
      ref = Process.monitor(runner)
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      :sys.get_state(:"#{ctx.sup}.Runners")
      assert runner_status(ctx.sup) == [:paused]

      {clock, _time} = Broker.clock(0)

      restarted =
        start_supervised!(
          {Heartbeat,
           name: :"heartbeat_#{System.unique_integer([:positive])}",
           timeout: 1_000,
           journal: ctx.journal,
           strategies: ctx.sup,
           clock: clock,
           schedule: fn _ms -> :ok end},
          id: :restarted
        )

      assert %{paused: true} = Heartbeat.status(restarted)
      :ok = Heartbeat.beat(restarted, "test")
      assert runner_status(ctx.sup) == [:running]
      assert Journal.pauses(ctx.journal) == {:ok, []}
    end

    test "only the heartbeat's resume ends a dead-man pause", ctx do
      assert {:error, {:resume_reason, "dead_man_resume"}} =
               Journal.record_halt(%{"reason" => "dead_man_resume"}, ctx.journal)
    end
  end
end

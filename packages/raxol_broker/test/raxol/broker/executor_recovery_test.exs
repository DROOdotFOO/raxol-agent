defmodule Raxol.Broker.ExecutorRecoveryTest do
  @moduledoc """
  Executor restarts and idempotency, status redaction, port reconnects, the
  clock, review receipts and start options (see
  `Raxol.Broker.Test.ExecutorCase`).
  """
  use Raxol.Broker.Test.ExecutorCase, async: true

  alias Raxol.Agent.Secret
  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.Executor.{Place, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.{ExecutorCase, ExecutorIdentity}
  alias Raxol.Broker.Test.ExecutorCase.EvilRegistry
  alias Raxol.Broker.Tools.Catalog

  @t0 ExecutorCase.t0()
  @day ExecutorCase.day()
  @account ExecutorCase.account()

  describe "restarts and idempotency" do
    test "an executor killed mid-review, then journal recovery and a re-run, places once",
         ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, :reviewing)
        Process.exit(executor, :kill)
        :hang
      end)

      intent = limit("restart-1")
      catch_exit(Executor.run(executor, intent, context()))
      assert_received :reviewing

      # Journal restarts too: its recovery closes the open group.
      restart_journal!(ctx)

      [first] = groups_for(ctx.path, "restart-1")
      assert List.last(group(ctx.path, first))["reason"] == "crash_before_verdict"

      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      executor = start_executor!(ctx)

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "an executor restart alone closes the group it left open", ctx do
      executor = start_executor!(ctx)

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        Process.exit(executor, :kill)
        :hang
      end)

      catch_exit(Executor.run(executor, limit("restart-2"), context()))
      [gid] = groups_for(ctx.path, "restart-2")
      assert Journal.open_groups(ctx.journal) == {:ok, [gid]}

      start_executor!(ctx)
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert List.last(group(ctx.path, gid))["reason"] == "executor_restarted"
    end

    test "a parked ASK does not survive a restart", ctx do
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, gid, _} = Executor.run(executor, limit("parked-restart"), context())

      stop_and_wait(executor)
      executor = start_executor!(ctx)

      assert Executor.approve(executor, gid, "droo") == {:error, {:not_parked, gid}}

      assert %{"type" => "close", "reason" => "executor_restarted"} =
               List.last(group(ctx.path, gid))

      assert Fake.calls(ctx.server, "place_") == []
    end

    test "a second executor on the same journal is refused; the first keeps its ASK", ctx do
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, gid, _} = Executor.run(executor, limit("claimed"), context())

      Process.flag(:trap_exit, true)

      assert Executor.start_link(executor_opts(ctx, [])) ==
               {:error, {:journal_claimed, executor}}

      assert [%{group_id: ^gid}] = Executor.parked(executor)
      assert Journal.open_groups(ctx.journal) == {:ok, [gid]}
      assert {:ok, %{status: :placed}} = Executor.approve(executor, gid, "droo")
    end

    test "a journal restart stops the executor; a fresh one claims and places", ctx do
      executor = start_executor!(ctx)
      ref = Process.monitor(executor)

      restart_journal!(ctx)
      assert_receive {:DOWN, ^ref, :process, ^executor, {:journal_down, _}}, 5_000

      executor = start_executor!(ctx)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("rejoin"), context())
    end

    test "only an executor process can claim the journal", ctx do
      assert Journal.claim(ctx.journal) == {:error, :not_an_executor}
    end

    test "a crash after placing is crash_outcome_unknown, counted, and never re-placed", ctx do
      executor = start_executor!(ctx)
      path = ctx.path

      Fake.on_call(ctx.server, "place_equity_order", fn _args ->
        Process.exit(writer(path), :kill)
        Process.exit(executor, :kill)
        :hang
      end)

      intent = limit("crash-placing")
      catch_exit(Executor.run(executor, intent, context()))
      restart_journal!(ctx)

      [gid] = groups_for(ctx.path, "crash-placing")
      assert List.last(group(ctx.path, gid))["reason"] == "crash_outcome_unknown"
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}

      Fake.on_call(ctx.server, "place_equity_order", fn _args -> :answer end)
      executor = start_executor!(ctx)
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a place call that times out is journaled :unknown and stays counted", ctx do
      executor = start_executor!(ctx, place_timeout: 100)
      Fake.on_call(ctx.server, "place_equity_order", fn _args -> :hang end)

      intent = limit("timeout")
      assert {:ok, %{group_id: gid, status: :unknown}} = Executor.run(executor, intent, context())

      assert %{"type" => "order", "status" => "unknown"} = List.last(group(ctx.path, gid))
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}
      assert Journal.orders_last_minute(@t0, ctx.journal) == {:ok, 1}
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
    end

    test "a JSON-RPC rejection is :failed and stops counting", ctx do
      executor = start_executor!(ctx)
      Fake.on_call(ctx.server, "place_equity_order", fn _args -> {:rpc_error, -32_602} end)

      assert {:ok, %{status: :failed}} = Executor.run(executor, limit("rejected"), context())
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("0")}
    end

    test "a 429 on place is :unknown, stays counted, and is never re-sent", ctx do
      executor = start_executor!(ctx)
      Fake.inject(ctx.server, [{"place_equity_order", {:http, 429}}])

      intent = limit("throttled")
      assert {:ok, %{group_id: gid, status: :unknown}} = Executor.run(executor, intent, context())
      assert %{"type" => "order", "status" => "unknown"} = List.last(group(ctx.path, gid))
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}

      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert [{"tools/call", "place_equity_order", 429}] = place_requests(ctx.server)
      assert Fake.orders(ctx.server) == []
    end

    test "a 429 on review places nothing and leaves the intent free to retry", ctx do
      executor = start_executor!(ctx)
      Fake.inject(ctx.server, [{"review_equity_order", {:http, 429}}])

      intent = limit("review-throttled")
      assert {:error, _reason} = Executor.run(executor, intent, context())
      assert place_requests(ctx.server) == []

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert [%{"state" => "queued"}] = Fake.orders(ctx.server)
    end
  end

  describe "status redaction" do
    test ":sys.get_status hides the receipt key, session spec and account", ctx do
      executor = start_executor!(ctx)
      key = :sys.get_state(executor).key
      {:status, _pid, _mod, [pdict, _sys, _parent, _dbg, misc]} = :sys.get_status(executor)
      dump = inspect(misc, structs: false, limit: :infinity)

      refute inspect(pdict, limit: :infinity) =~ inspect(key)

      refute dump =~ @account
      assert dump =~ "client_spec: :redacted"
      assert dump =~ "key: :redacted"
    end

    test "format_status/1 reduces the failure terms and empties the debug log" do
      spec = [headers: [{"authorization", "Bearer leak"}]]
      exit = {%FunctionClauseError{module: M, function: :f, arity: 1}, [{M, :f, [spec], []}]}

      status =
        Executor.format_status(%{
          state: %{key: "k", client_spec: spec, account: "ACC"},
          reason: {:port_exited, exit},
          message: {:EXIT, self(), spec},
          log: [{:in, spec}]
        })

      assert status.reason == {:port_exited, FunctionClauseError}
      assert status.message =~ ":EXIT"
      assert status.log == []
      refute inspect(status) =~ "leak"
      refute inspect(status) =~ "ACC"
    end
  end

  describe "port" do
    test "a killed port client reconnects and the executor places again", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)

      stop_and_wait(client)
      assert Process.alive?(executor)

      assert :ok = Executor.await_port(executor, 5_000)
      assert %{port: {PortMCP, %{pid: new_client}}} = :sys.get_state(executor)
      assert new_client != client
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("back"), context())
    end

    test "an unreachable session starts, refuses until ready, then places", ctx do
      {:ok, dns} = Agent.start_link(fn -> {:error, :nxdomain} end)

      session =
        Keyword.put(Fake.session(ctx.server), :resolver, fn host, family ->
          case Agent.get(dns, & &1) do
            {:error, reason} -> {:error, reason}
            :ok -> Fake.session(ctx.server)[:resolver].(host, family)
          end
        end)

      {:ok, executor} =
        Executor.start_link(executor_opts(ctx, session: session, reconnect_ms: 10))

      Fake.warnings(ctx.server, ["halted"])
      assert Executor.run(executor, limit("early"), context()) == {:error, :port_not_ready}
      assert Executor.await_port(executor, 0) == {:error, :port_not_ready}
      assert groups_for(ctx.path, "early") == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert Fake.exchanges(ctx.server) == 0

      Agent.update(dns, fn _ -> :ok end)
      assert :ok = Executor.await_port(executor, 5_000)

      Fake.warnings(ctx.server, [])
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("later"), context())
    end
  end

  describe "clock" do
    test "runs outside the executor: no claim", ctx do
      test_pid = self()
      journal = ctx.journal

      clock = fn ->
        send(test_pid, {:clock, Journal.claim(journal)})
        @t0
      end

      executor = start_executor!(ctx, clock: clock)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("clock"), context())
      assert_received {:clock, {:error, :not_an_executor}}
    end

    test "a clock that returns something other than a UTC DateTime places nothing", ctx do
      {:ok, clocks} = Agent.start_link(fn -> fn -> @t0 end end)
      executor = start_executor!(ctx, clock: fn -> Agent.get(clocks, & &1).() end)

      for bad <- [fn -> :now end, fn -> raise "boom" end, fn -> ~N[2026-10-02 14:30:00] end] do
        Agent.update(clocks, fn _ -> bad end)
        assert {:error, {:context, _}} = Executor.run(executor, limit("bad-clock"), context())
      end

      assert groups_for(ctx.path, "bad-clock") == []
      assert Fake.calls(ctx.server) == []
    end
  end

  describe "review receipts" do
    setup ctx do
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      intent = limit("rcpt")
      {:ask, gid, _} = Executor.run(executor, intent, context())
      {:ok, port} = PortMCP.start(Fake.session(ctx.server), mode: :dry_run)
      key = :crypto.strong_rand_bytes(32)

      env = %{
        port: port,
        catalog: Catalog.static(),
        journal: ctx.journal,
        account: @account,
        key: Secret.new(key),
        timeout: 5_000
      }

      {:ok, executor: executor, intent: intent, gid: gid, key: key, env: env}
    end

    test "a key that is not a Secret is refused; nothing is sent", ctx do
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)

      for key <- [ctx.key, nil] do
        env = %{ctx.env | key: key}
        assert Place.run(receipt, ctx.intent, ctx.gid, env) == {:error, :invalid_receipt}
      end

      assert Fake.calls(ctx.server, "place_") == []
      refute "placing" in types(ctx.path, ctx.gid)
    end

    test "a receipt is bound to the whole intent, its group and the key", ctx do
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)
      foreign = ReviewReceipt.issue(:crypto.strong_rand_bytes(32), ctx.intent, ctx.gid)

      {:ok, bigger} =
        Intent.limit(:buy, "AAPL", d("20"), d("125"), provenance: :strategy, id: "rcpt")

      for {receipt, intent, gid} <- [
            {receipt, limit("someone-else"), ctx.gid},
            {receipt, bigger, ctx.gid},
            {receipt, ctx.intent, "other-group"},
            {foreign, ctx.intent, ctx.gid},
            {%{mac: "x"}, ctx.intent, ctx.gid}
          ] do
        assert Place.run(receipt, intent, gid, ctx.env) == {:error, :invalid_receipt}
      end

      assert Fake.calls(ctx.server, "place_") == []
    end

    test "a valid receipt from a process that is not the claimant is refused", ctx do
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)

      assert Place.run(receipt, ctx.intent, ctx.gid, ctx.env) ==
               {:error, {:not_claimant, ctx.gid}}

      assert Fake.calls(ctx.server, "place_") == []
      refute "placing" in types(ctx.path, ctx.gid)
    end

    test "a receipt from a real parked group cannot be replayed", ctx do
      state = :sys.get_state(ctx.executor)
      receipt = state.parked[ctx.gid].receipt
      assert {:ok, %{status: :placed}} = Executor.approve(ctx.executor, ctx.gid, "droo")

      stop_and_wait(ctx.executor)
      ExecutorIdentity.assume!(ctx.journal)
      env = %{ctx.env | key: Secret.new(state.key)}

      assert {:error, _refused} = Place.run(receipt, ctx.intent, ctx.gid, env)

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
      assert Enum.count(types(ctx.path, ctx.gid), &(&1 == "placing")) == 1
    end
  end

  describe "start options" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "armed mode is refused until arming exists", ctx do
      assert Executor.start_link(executor_opts(ctx, mode: :armed)) == {:error, :not_armed}
    end

    test "a missing or invalid policy is refused", ctx do
      opts = Keyword.delete(executor_opts(ctx, []), :policy)
      assert {:error, {:invalid_policy, _}} = Executor.start_link(opts)

      assert {:error, {:invalid_policy, _}} =
               Executor.start_link(executor_opts(ctx, policy: [bogus: 1]))
    end

    test "a timeout that is not an integer in 1..4_294_000_000 is refused", ctx do
      for {key, bad} <- [
            review_timeout: :infinity,
            place_timeout: 0,
            review_timeout: "5",
            place_timeout: 4_294_967_296,
            review_timeout: 4_294_000_001,
            reconnect_ms: 0
          ] do
        assert Executor.start_link(executor_opts(ctx, [{key, bad}])) ==
                 {:error, {:invalid_timeout, key, bad}}
      end
    end

    test "a journal that is not running is refused", ctx do
      assert Executor.start_link(executor_opts(ctx, journal: :no_such_journal)) ==
               {:error, :journal_not_running}
    end

    test "a journal that is not an atom or pid is refused before any of its code runs", ctx do
      for journal <- [{:via, EvilRegistry, self()}, {:global, self()}, "x", nil] do
        assert Executor.start_link(executor_opts(ctx, journal: journal)) ==
                 {:error, {:invalid_journal, journal}}
      end

      refute_received {:evil_registry, _pid}
    end

    test "a clock that is not a zero-arity function is refused", ctx do
      clock = fn _ -> @t0 end

      assert Executor.start_link(executor_opts(ctx, clock: clock)) ==
               {:error, {:invalid_clock, clock}}
    end

    test "child_spec/1 waits out a place call on shutdown; :shutdown overrides" do
      assert %{shutdown: 35_000, id: Executor} = Executor.child_spec([])

      assert %{shutdown: 7_000} =
               Executor.child_spec(review_timeout: 1_000, place_timeout: 2_000)

      assert %{shutdown: 35_000} = Executor.child_spec(place_timeout: :bogus)
      assert %{shutdown: 120_000} = Executor.child_spec(place_timeout: 2_000, shutdown: 120_000)

      for bad <- [0, -1, :infinity, 1.5, "60000"] do
        assert_raise ArgumentError, fn -> Executor.child_spec(shutdown: bad) end
      end
    end

    test "a session that reaches Robinhood, or is not marked sandbox, is refused", ctx do
      session = Fake.session(ctx.server)
      live = Keyword.put(session, :url, "https://agent.robinhood.com/mcp/trading")
      unmarked = Keyword.delete(session, :sandbox)

      for spec <- [live, unmarked] do
        assert Executor.start_link(executor_opts(ctx, session: spec)) ==
                 {:error, :live_port_in_dry_run}
      end

      assert Fake.calls(ctx.server) == []
    end
  end
end

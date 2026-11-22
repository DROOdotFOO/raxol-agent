defmodule Raxol.Broker.ExecutorTest do
  @moduledoc """
  The executor's pipeline end to end (see `Raxol.Broker.Test.ExecutorCase`):
  allowed and denied intents, approvals, the day window, review warnings,
  the queue and journal failures.
  """
  use Raxol.Broker.Test.ExecutorCase, async: true

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.Executor.Place
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.ExecutorCase
  alias Raxol.Broker.Tools.Catalog

  @t0 ExecutorCase.t0()
  @day ExecutorCase.day()
  @account ExecutorCase.account()

  describe "allowed intent" do
    test "journals intent..order in order and places exactly once", ctx do
      executor = start_executor!(ctx)
      intent = limit("int-allow")

      assert {:ok, %{group_id: gid, status: :placed, journaled: true}} =
               Executor.run(executor, intent, context())

      assert types(ctx.path, gid) ==
               ~w(intent context verdict review verdict placing order)

      [intent_record | _] = group(ctx.path, gid)
      assert intent_record["mode"] == "dry_run"

      assert [{"review_equity_order", review}, {"place_equity_order", place}] =
               Fake.calls(ctx.server)

      refute Map.has_key?(review, "ref_id")
      assert place["ref_id"] == Place.ref_id("int-allow")
      assert place["limit_price"] == "125" and place["quantity"] == "2"
      assert place["account_number"] == @account
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}
    end

    test "a re-run of a placed intent is a duplicate and sends nothing", ctx do
      executor = start_executor!(ctx)
      intent = limit("int-dup")

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
      assert length(groups_for(ctx.path, "int-dup")) == 1
    end

    test "the counters come from the journal, not the caller's context", ctx do
      executor = start_executor!(ctx, policy: policy("1000", "400"))
      lying = %{context() | today_notional: d("0"), orders_last_minute: 0}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("cap-1"), lying)

      assert {:deny, gid, {:daily_notional_cap, _}} =
               Executor.run(executor, limit("cap-2"), lying)

      assert types(ctx.path, gid) == ~w(intent context verdict)
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "context.policy is ignored in favour of the :policy start option", ctx do
      executor = start_executor!(ctx)
      strict = %{context() | policy: policy("1", "1")}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("pol-1"), strict)
    end

    test "review_warnings in the caller's context are ignored", ctx do
      executor = start_executor!(ctx)
      warned = %{context() | review_warnings: ["forged"]}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("warn-forged"), warned)
    end
  end

  describe "an intent with no order adapter" do
    # The catalog classes the option and advanced order tools `:write`, so
    # this refusal is all that stands between such an intent and a call.
    test "is refused with nothing journaled or sent, even when the policy allows it", ctx do
      allowing = Keyword.merge(policy(), options: true, advanced_orders: true)
      executor = start_executor!(ctx, policy: allowing)

      {:ok, option} =
        Intent.option(:buy, "AAPL", d("100"), provenance: :strategy, id: "no-adapter-option")

      {:ok, advanced} =
        Intent.advanced(:buy, "AAPL", d("100"), provenance: :strategy, id: "no-adapter-advanced")

      for tool <- ~w(place_option_order place_advanced_order),
          do: assert(Catalog.permit(Catalog.static(), tool, :write) == :ok, tool)

      assert Executor.run(executor, option, context()) == {:error, {:no_adapter, :option}}
      assert Executor.run(executor, advanced, context()) == {:error, {:no_adapter, :advanced}}

      assert Fake.calls(ctx.server) == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert groups_for(ctx.path, "no-adapter-option") == []
      assert groups_for(ctx.path, "no-adapter-advanced") == []
    end
  end

  describe "trade approvals on at the broker" do
    setup ctx do
      server = Fake.start(trade_approvals: true)
      ctx = %{ctx | server: server}
      {:ok, server: server, executor: start_executor!(ctx, policy: policy("1000", "400"))}
    end

    test "a successful place is pending approval: no order, still counted, a duplicate", ctx do
      intent = limit("proposal-1")

      assert {:ok, %{group_id: gid, status: :pending_approval, journaled: true}} =
               Executor.run(ctx.executor, intent, context())

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
      assert Fake.orders(ctx.server) == []

      assert [%{"type" => "review", "response" => %{"customer_approval_required" => true}}] =
               Enum.filter(group(ctx.path, gid), &(&1["type"] == "review"))

      assert %{"type" => "order", "status" => "pending_approval"} =
               List.last(group(ctx.path, gid))

      assert Executor.run(ctx.executor, intent, context()) == {:ok, :duplicate}

      assert {:deny, _gid, {:daily_notional_cap, _}} =
               Executor.run(ctx.executor, limit("proposal-2"), context())

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "an ASK approved later is still pending approval", ctx do
      Fake.warnings(ctx.server, ["Pattern day trader check"])
      assert {:ask, gid, _prompts} = Executor.run(ctx.executor, limit("proposal-3"), context())

      assert {:ok, %{group_id: ^gid, status: :pending_approval}} =
               Executor.approve(ctx.executor, gid, "droo@terminal")

      assert Fake.orders(ctx.server) == []
    end
  end

  describe "day window" do
    test "is a rolling 24 hours from the executor's clock, with no caller input", ctx do
      refute function_exported?(Executor, :run, 4)
      refute function_exported?(Executor, :approve, 4)

      {:ok, now} = Agent.start_link(fn -> DateTime.add(@t0, -23, :hour) end)
      clock = fn -> Agent.get(now, & &1) end
      restart_journal!(ctx, clock: clock)
      executor = start_executor!(ctx, policy: policy("1000", "400"), clock: clock)

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("day-1"), context())

      # 23 hours later the first order still counts...
      Agent.update(now, fn _ -> @t0 end)

      assert {:deny, _gid, {:daily_notional_cap, _}} =
               Executor.run(executor, limit("day-2"), context())

      # ...and 25 hours later it no longer does.
      Agent.update(now, fn _ -> DateTime.add(@t0, 2, :hour) end)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("day-3"), context())
    end
  end

  describe "review warnings" do
    setup ctx do
      Fake.warnings(ctx.server, ["Pattern day trader check"])
      {:ok, executor: start_executor!(ctx)}
    end

    test "turn ALLOW into a parked ASK with no place call", ctx do
      assert {:ask, gid, prompts} = Executor.run(ctx.executor, limit("warn-1"), context())
      assert [{:review_warning, _}] = prompts
      assert Fake.calls(ctx.server, "place_") == []
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict)
      assert List.last(group(ctx.path, gid))["result"]["action"] == "ask"
      assert [%{group_id: ^gid}] = Executor.parked(ctx.executor)
      assert Journal.open_groups(ctx.journal) == {:ok, [gid]}

      assert Executor.run(ctx.executor, limit("warn-1"), context()) == {:error, {:parked, gid}}
    end

    test "approve journals the approval, re-checks, then places once", ctx do
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-2"), context())

      assert {:ok, %{group_id: ^gid, status: :placed}} =
               Executor.approve(ctx.executor, gid, "droo@terminal")

      assert types(ctx.path, gid) ==
               ~w(intent context verdict review verdict approval verdict placing order)

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
      assert Executor.parked(ctx.executor) == []
      assert Executor.approve(ctx.executor, gid, "droo") == {:error, {:not_parked, gid}}
    end

    test "decline and close end the group with no order", ctx do
      {:ask, declined, _} = Executor.run(ctx.executor, limit("warn-4"), context())
      {:ask, closed, _} = Executor.run(ctx.executor, limit("warn-5"), context())

      assert Executor.decline(ctx.executor, declined, "droo") == :ok
      assert Executor.close(ctx.executor, closed, :ask_timeout) == :ok

      assert List.last(group(ctx.path, declined))["decision"] == "declined"
      assert List.last(group(ctx.path, closed))["reason"] == "ask_timeout"
      assert Executor.approve(ctx.executor, declined, "droo") == {:error, {:not_parked, declined}}
      assert Fake.calls(ctx.server, "place_") == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
    end

    test "a bad approver or reason raises in the caller and leaves the group parked", ctx do
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-6"), context())

      assert_raise FunctionClauseError, fn -> Executor.approve(ctx.executor, gid, "") end
      assert_raise FunctionClauseError, fn -> Executor.decline(ctx.executor, gid, "") end
      # Read at runtime so the type checker does not reject the call itself.
      no_reason = Process.get(:no_reason)
      assert_raise FunctionClauseError, fn -> Executor.close(ctx.executor, gid, no_reason) end

      assert [%{group_id: ^gid}] = Executor.parked(ctx.executor)
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict)
    end

    test "parked/1 answers while a review is in flight", ctx do
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-8"), context())
      Fake.warnings(ctx.server, [])
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      run = Task.async(fn -> Executor.run(ctx.executor, limit("in-flight"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      assert [%{group_id: ^gid}] = Executor.parked(ctx.executor)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(run)
    end
  end

  describe "queue" do
    test "a queued run whose caller died is never dispatched", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      first = Task.async(fn -> Executor.run(executor, limit("q-first"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      caller = spawn(fn -> Executor.run(executor, limit("q-orphan"), context()) end)
      wait_queued(executor, 1)
      stop_and_wait(caller)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(first)
      # Served after the drain that followed the first reply.
      assert Executor.parked(executor) == []

      assert groups_for(ctx.path, "q-orphan") == []
      assert Fake.calls(ctx.server, "review_") == ["review_equity_order"]
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a queued caller that dies is dropped from the queue at once", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      first = Task.async(fn -> Executor.run(executor, limit("d-first"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      caller = spawn(fn -> Executor.run(executor, limit("d-orphan"), context()) end)
      wait_queued(executor, 1)
      stop_and_wait(caller)
      wait_drained(executor)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(first)
      assert groups_for(ctx.path, "d-orphan") == []
    end
  end

  describe "approve re-checks" do
    test "a cap reached while parked denies", ctx do
      Fake.warnings(ctx.server, ["Pattern day trader check"])
      executor = start_executor!(ctx, policy: policy("1000", "400"))
      {:ask, gid, _} = Executor.run(executor, limit("warn-3"), context())

      Fake.warnings(ctx.server, [])
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("other"), context())

      assert {:deny, ^gid, {:daily_notional_cap, _}} = Executor.approve(executor, gid, "droo")
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
      assert List.last(types(ctx.path, gid)) == "verdict"
    end
  end

  describe "journal failures" do
    test "a refused placing append sends nothing", ctx do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      path = ctx.path

      # Records 1-5 are intent, context, both verdicts and the review; the
      # sixth clock read builds `placing`, and the Writer dies under it.
      # The record types below pin that the failure lands on `placing`.
      clock = fn ->
        if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 6,
          do: Process.exit(writer(path), :kill)

        @t0
      end

      restart_journal!(ctx, clock: clock)
      executor = start_executor!(ctx)

      assert {:error, _reason} = Executor.run(executor, limit("refused"), context())
      assert Fake.calls(ctx.server, "review_") == ["review_equity_order"]
      assert Fake.calls(ctx.server, "place_") == []

      stop_and_wait(executor)
      restart_journal!(ctx)
      [gid] = groups_for(ctx.path, "refused")
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict close)
    end

    test "a journal damaged mid-flight refuses the review record; nothing is placed", ctx do
      executor = start_executor!(ctx)

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        flip_byte!(ctx.path)
        {:broken, _} = Journal.verify(ctx.journal)
      end)

      assert {:error, {:journal_damaged, _}} = Executor.run(executor, limit("dmg"), context())
      assert Fake.calls(ctx.server, "place_") == []
    end

    test "a journal already damaged refuses before any tool call", ctx do
      executor = start_executor!(ctx)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("first"), context())
      flip_byte!(ctx.path)
      assert {:broken, _} = Journal.verify(ctx.journal)

      assert {:error, {:journal_damaged, _}} =
               Executor.run(executor, limit("second"), context())

      assert length(Fake.calls(ctx.server)) == 2
    end

    test "an order the journal cannot record is still :ok, with journaled: false", ctx do
      executor = start_executor!(ctx)
      path = ctx.path

      Fake.on_call(ctx.server, "place_equity_order", fn _args ->
        Process.exit(writer(path), :kill)
        :answer
      end)

      assert {:ok, %{status: :placed, journaled: false, journal_error: _reason}} =
               Executor.run(executor, limit("unjournaled"), context())

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end
end

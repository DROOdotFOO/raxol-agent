defmodule Raxol.Broker.Executor.ReconcileTest do
  @moduledoc """
  Reconciliation of unknown orders and pending proposals against the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @day ~U[2026-10-02 04:00:00Z]

  defp broker!(fake_opts \\ [], executor_opts \\ []) do
    ctx = Broker.journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    fake = Fake.start(fake_opts)
    executor = Broker.executor!(ctx.journal, fake, executor_opts)
    Map.merge(ctx, %{fake: fake, executor: executor})
  end

  defp limit(id) do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :strategy, id: id)
    intent
  end

  defp run(ctx, id), do: Executor.run(ctx.executor, limit(id), %Context{})
  defp notional(ctx), do: elem(Journal.today_notional(@day, ctx.journal), 1)

  test "an unknown order the broker has is resolved placed and keeps counting" do
    ctx = broker!([], place_timeout: 100)
    test = self()

    Fake.on_call(ctx.fake, "place_equity_order", fn _args ->
      send(test, {:placing, self()})
      receive do: (:go -> :answer)
    end)

    assert {:ok, %{status: :unknown}} = run(ctx, "late")
    assert_receive {:placing, place}
    ref = Process.monitor(place)
    send(place, :go)
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert {:ok, [%{intent_id: "late", resolution: "placed"}]} = Executor.reconcile(ctx.executor)
    assert Decimal.equal?(notional(ctx), d("250"))
    assert Journal.unresolved(ctx.journal) == {:ok, []}
    assert run(ctx, "late") == {:ok, :duplicate}
  end

  test "an unknown order the broker never got is resolved absent once old enough" do
    {:ok, clock} = Agent.start_link(fn -> Broker.t0() end)

    ctx =
      broker!([faults: [{"place_equity_order", {:http, 503}}]],
        clock: fn -> Agent.get(clock, & &1) end
      )

    assert {:ok, %{status: :unknown}} = run(ctx, "lost")
    assert Decimal.equal?(notional(ctx), d("250"))

    # Still young: it may be on its way.
    assert {:ok, []} = Executor.reconcile(ctx.executor)
    assert Decimal.equal?(notional(ctx), d("250"))

    Agent.update(clock, &DateTime.add(&1, 120, :second))
    assert {:ok, [%{resolution: "absent"}]} = Executor.reconcile(ctx.executor)
    assert Decimal.equal?(notional(ctx), d("0"))
    assert {:ok, %{status: :placed}} = run(ctx, "lost")
  end

  test "an unknown order whose review asked for approval is never taken for absent" do
    ctx =
      broker!([trade_approvals: true, faults: [{"place_equity_order", {:http, 503}}]],
        reconcile_min_age_ms: 0
      )

    assert {:ok, %{status: :unknown}} = run(ctx, "proposal-lost")
    assert {:ok, []} = Executor.reconcile(ctx.executor)
    assert Decimal.equal?(notional(ctx), d("250"))

    assert {:ok, [%{"approval_required" => true, "status" => "unknown"}]} =
             Journal.unresolved(ctx.journal)
  end

  test "only the executor may resolve a group" do
    ctx = broker!([faults: [{"place_equity_order", {:http, 503}}]], reconcile_min_age_ms: 0)
    assert {:ok, %{status: :unknown}} = run(ctx, "forged")
    {:ok, [%{"group_id" => gid}]} = Journal.unresolved(ctx.journal)

    assert Journal.resolve(gid, "absent", %{}, ctx.journal) == {:error, {:not_claimant, gid}}
    assert Decimal.equal?(notional(ctx), d("250"))
  end

  test "a declined or expired proposal releases the cap; an approved one keeps counting" do
    ctx = broker!(trade_approvals: true)

    for id <- ~w(declined expired approved pending),
        do: assert({:ok, %{status: :pending_approval}} = run(ctx, id))

    assert Decimal.equal?(notional(ctx), d("1000"))

    [declined, expired, approved, _pending] =
      Enum.map(Fake.approvals(ctx.fake), & &1["approval_id"])

    Fake.resolve_approval(ctx.fake, declined, "declined")
    Fake.resolve_approval(ctx.fake, expired, "expired")
    Fake.resolve_approval(ctx.fake, approved, "approved")

    assert {:ok, resolved} = Executor.reconcile(ctx.executor)

    assert Enum.sort(Enum.map(resolved, &{&1.intent_id, &1.resolution})) ==
             [{"approved", "approved"}, {"declined", "declined"}, {"expired", "expired"}]

    assert Decimal.equal?(notional(ctx), d("500"))

    assert {:ok, [%{"intent_id" => "pending", "status" => "pending_approval"}]} =
             Journal.unresolved(ctx.journal)

    approval =
      Enum.find(
        Broker.records(ctx.path),
        &(&1["type"] == "resolve" and &1["resolution"] == "approved")
      )

    assert approval["detail"]["order_id"] =~ "ord-"
  end

  test "resolutions survive a journal restart" do
    ctx = broker!([faults: [{"place_equity_order", {:http, 503}}]], reconcile_min_age_ms: 0)
    assert {:ok, %{status: :unknown}} = run(ctx, "lost")
    assert {:ok, [_]} = Executor.reconcile(ctx.executor)

    pid = GenServer.whereis(ctx.journal)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
    Broker.start_journal!(ctx.journal_opts)

    assert Decimal.equal?(notional(ctx), d("0"))
    assert Journal.unresolved(ctx.journal) == {:ok, []}
  end
end

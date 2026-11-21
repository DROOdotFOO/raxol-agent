defmodule Raxol.Agent.SpendGate.ControlsTest do
  @moduledoc """
  Negative controls for `ReserveBeforeCallTest`: each injector is a gate with
  one deliberate bug, and its checker must flag it. The last tests show the
  checkers pass a well-formed trace and that an armed injector that never
  fires is reported.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Test.SpendGateProbe, as: P

  alias Raxol.Agent.Test.SpendGateProbe.{
    CallOnRefusedInjector,
    CrashLosesReserveInjector,
    DoubleSettleInjector,
    DualTruthInjector,
    DuplicateReserveInjector,
    SettleOnlyInjector
  }

  test "dead injector: settle-only (post-hoc accounting) fails the order check" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:settle_only)
    ctx = %{emit: P.emit_fun(j), probe: probe, budget: P.new_budget(1000)}

    assert {:ok, _} = SettleOnlyInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 80))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:settle]
    # The order checker flags the missing reserve — green-on-broken is impossible.
    assert {:error, {:bad_order, "c1", [:settle]}} = P.reserve_before_call(recs)
    P.assert_all_fired!(probe, [:settle_only])
  end

  test "dead injector: calling the provider on a refused reserve fails the fail-closed check" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:call_on_refused)
    # Cap 0 ⇒ every reserve is refused.
    budget = P.new_budget(0)

    ctx = %{
      emit: P.emit_fun(j),
      probe: probe,
      budget: budget,
      try_reserve: P.try_reserve_fun(budget)
    }

    assert {:error, {:reserve_refused, _}} =
             CallOnRefusedInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 100))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:reserve_refused]
    # The stub call-counter caught the illegal provider call: 1 seen, 0 allowed.
    assert P.provider_calls(p) == 1
    assert {:error, {:provider_calls, 1, 0}} = P.fail_closed(recs, P.provider_calls(p), 0)
    P.assert_all_fired!(probe, [:call_on_refused])
  end

  test "dead injector: reserving against a stale/second counter (dual-truth) fails the no-over-reserve check" do
    cap = 300
    est = 100
    n = 10
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:dual_truth)
    ctx = %{emit: P.emit_fun(j), probe: probe, budget: P.new_budget(cap)}

    for i <- 1..n do
      assert {:ok, _} = DualTruthInjector.around(ctx, "c#{i}", est, P.call_fun(p, "c#{i}", est))
    end

    recs = P.records(j)
    # 10 reserves * 100 = 1000 tokens reserved against a 300 cap — over-reserve.
    assert {:error, {:over_reserve, 1000, 300}} = P.reserved_within_cap(recs, cap)
    assert P.provider_calls(p) == n
    P.assert_all_fired!(probe, [:dual_truth])
  end

  test "dead injector: losing a reserve on crash fails the dangling-reserve-visible check" do
    j = P.new_journal()
    probe = P.new_probe() |> P.arm(:crash_loses_reserve)
    ctx = %{emit: P.emit_fun(j), probe: probe, budget: P.new_budget(1000)}

    assert {:ok, _} = CrashLosesReserveInjector.reserve(ctx, "c1", 100)

    recs = P.records(j)
    # The reserve was never journaled ⇒ silently lost on crash.
    assert recs == []
    assert P.dangling_reserve_visible(recs, "c1") == {:error, :reserve_lost}
    P.assert_all_fired!(probe, [:crash_loses_reserve])
  end

  test "dead injector: reserving the same cost_ref twice fails the order check" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:duplicate_reserve)
    budget = P.new_budget(1000)

    ctx = %{
      emit: P.emit_fun(j),
      probe: probe,
      budget: budget,
      try_reserve: P.try_reserve_fun(budget)
    }

    assert {:ok, _} = DuplicateReserveInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 80))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:reserve, :reserve, :call, :settle]

    assert {:error, {:bad_order, "c1", [:reserve, :reserve, :call, :settle]}} =
             P.reserve_before_call(recs)

    P.assert_all_fired!(probe, [:duplicate_reserve])
  end

  test "dead injector: settling the same reservation twice fails the double-settle check" do
    j = P.new_journal()
    p = P.new_provider()
    probe = P.new_probe() |> P.arm(:double_settle)
    budget = P.new_budget(1000)

    ctx = %{
      emit: P.emit_fun(j),
      probe: probe,
      budget: budget,
      try_reserve: P.try_reserve_fun(budget)
    }

    assert {:ok, _} = DoubleSettleInjector.around(ctx, "c1", 100, P.call_fun(p, "c1", 70))

    recs = P.records(j)
    assert P.kinds_for(recs, "c1") == [:reserve, :call, :settle, :settle]
    assert {:error, {:double_settle, "c1", 2}} = P.no_double_settle(recs)
    # The generic order checker independently flags the same trace too.
    assert {:error, {:bad_order, "c1", [:reserve, :call, :settle, :settle]}} =
             P.reserve_before_call(recs)

    P.assert_all_fired!(probe, [:double_settle])
  end

  test "the order checker already rejects a bare duplicate-reserve trace via bad_order" do
    j = P.new_journal()
    emit = P.emit_fun(j)
    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    recs = P.records(j)

    assert {:error, {:bad_order, "c1", [:reserve, :reserve]}} = P.reserve_before_call(recs)
  end

  test "the checkers pass a well-formed trace" do
    j = P.new_journal()
    emit = P.emit_fun(j)
    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    emit.(%{kind: :call, cost_ref: "c1"})
    emit.(%{kind: :settle, cost_ref: "c1", actual: 70})
    recs = P.records(j)

    assert P.reserve_before_call(recs) == :ok
    assert P.fail_closed(recs, 1, 1) == :ok
    assert P.reserved_within_cap(recs, 300) == :ok
    assert P.no_double_settle(recs) == :ok
    # A settled reserve is not dangling — the crash contour's negative direction.
    assert P.dangling_reserve_visible(recs, "c1") == {:error, :not_dangling}
  end

  test "peak, not cumulative: a refund-and-reuse trace stays within cap under peak tracking" do
    # A legitimate reserve->settle->reserve sequence: c1 reserves 100 but only
    # spends 20 (settling early frees 80 back to the pool), then c2 reserves
    # 100 and spends 90. The two estimates sum to 200 > a 150 cap, but they
    # are never concurrently outstanding, so the PEAK concurrent reserved
    # never exceeds the cap.
    j = P.new_journal()
    emit = P.emit_fun(j)
    cap = 150

    emit.(%{kind: :reserve, cost_ref: "c1", estimate: 100})
    emit.(%{kind: :call, cost_ref: "c1"})
    emit.(%{kind: :settle, cost_ref: "c1", actual: 20})
    emit.(%{kind: :reserve, cost_ref: "c2", estimate: 100})
    emit.(%{kind: :call, cost_ref: "c2"})
    emit.(%{kind: :settle, cost_ref: "c2", actual: 90})
    recs = P.records(j)

    assert P.reserved_within_cap(recs, cap) == :ok

    # Pin that peak tracking (not a raised cap) is what makes this pass: the
    # naive cumulative sum of every :reserve estimate WOULD have wrongly
    # rejected this well-formed, budget-respecting trace.
    cumulative =
      recs |> Enum.filter(&(&1.kind == :reserve)) |> Enum.map(& &1.estimate) |> Enum.sum()

    assert cumulative > cap
  end

  test "an armed injector that never fires fails assert_all_fired! and dumps the schedule" do
    probe = P.new_probe() |> P.arm(:settle_only) |> P.arm(:dual_truth)
    P.fire(probe, :settle_only)

    err =
      assert_raise ExUnit.AssertionError, fn ->
        P.assert_all_fired!(probe, [:the, :schedule])
      end

    assert err.message =~ "dead injector"
    assert err.message =~ "dual_truth"
    refute err.message =~ ~r/dead injector.*settle_only/
    assert err.message =~ "[:the, :schedule]"
  end
end

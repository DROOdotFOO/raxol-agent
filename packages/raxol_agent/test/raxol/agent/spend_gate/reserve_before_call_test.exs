defmodule Raxol.Agent.SpendGate.ReserveBeforeCallTest do
  @moduledoc """
  The reserve-before-call law of `Raxol.Agent.SpendGate`: every spend-bearing
  call journals `reserve → call → settle` per `cost_ref`, a refused reserve
  makes no call, a crash leaves its reserve visible in the fold, concurrent
  calls never reserve past the cap, and a `cost_ref` reserves and settles at
  most once. `ControlsTest` shows each checker catches a broken gate.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.SpendGate
  alias Raxol.Agent.SpendGateProbe, as: P

  # Read at run time so `SPEND_GATE_SEED=...` works on an already compiled
  # suite; failure messages carry it.
  defp seed, do: String.to_integer(System.get_env("SPEND_GATE_SEED", "424242"))

  defp ctx(journal, budget),
    do: %{
      emit: P.emit_fun(journal),
      try_reserve: P.try_reserve_fun(budget),
      budget: budget,
      agent_id: :spend_gate_test
    }

  describe "the real gate" do
    test "reserve→call→settle, in order, per call (fold asserts; cost_ref correlation)" do
      j = P.new_journal()
      p = P.new_provider()
      ctx = ctx(j, P.new_budget(1000))

      # actual (80) < estimate (100): under-estimate, refund due.
      assert {:ok, {:result, "c1"}} =
               SpendGate.around(ctx, "c1", 100, P.call_fun(p, "c1", 80))

      recs = P.records(j)
      assert P.reserve_before_call(recs) == :ok
      assert P.kinds_for(recs, "c1") == [:reserve, :call, :settle]
      assert P.provider_calls(p) == 1
    end

    test "a refused reserve makes no provider call and records a typed refusal" do
      j = P.new_journal()
      p = P.new_provider()
      # Cap fits exactly one 100-token call: the second must be refused.
      ctx = ctx(j, P.new_budget(100))

      assert {:ok, _} = SpendGate.around(ctx, "c1", 100, P.call_fun(p, "c1", 100))

      assert {:error, {:reserve_refused, _reason}} =
               SpendGate.around(ctx, "c2", 100, P.call_fun(p, "c2", 100))

      recs = P.records(j)
      assert P.kinds_for(recs, "c1") == [:reserve, :call, :settle]
      # The typed refusal event is present; the call never happened.
      assert P.kinds_for(recs, "c2") == [:reserve_refused]
      assert P.provider_calls(p) == 1
      assert P.fail_closed(recs, P.provider_calls(p), 1) == :ok
    end

    test "settle records the actual; the refund (estimate - actual) is derivable from the pair" do
      j = P.new_journal()
      p = P.new_provider()
      ctx = ctx(j, P.new_budget(1000))

      # actual (70) < estimate (100): under-estimate, refund due.
      assert {:ok, _} = SpendGate.around(ctx, "c1", 100, P.call_fun(p, "c1", 70))

      recs = P.records(j)
      assert %{estimate: 100} = Enum.find(recs, &(&1.kind == :reserve and &1.cost_ref == "c1"))
      assert %{actual: 70} = Enum.find(recs, &(&1.kind == :settle and &1.cost_ref == "c1"))
      # Refund is a derived fact, not a separate record; the settle is authoritative.
      assert P.reserve_before_call(recs) == :ok
    end

    test "a crash between reserve and call leaves the reserve visible in the fold" do
      j = P.new_journal()
      ctx = ctx(j, P.new_budget(1000))
      parent = self()

      # A real kill after reserve/3 returns: the reserve was journaled before
      # it returned, so the journal still shows it.
      {pid, ref} =
        spawn_monitor(fn ->
          _ = SpendGate.reserve(ctx, "c1", 100)
          send(parent, :reserved)
          # Would call the provider next — but the crash happens first.
          Process.sleep(:infinity)
        end)

      assert_receive :reserved, 1_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      recs = P.records(j)
      assert P.dangling_reserve_visible(recs, "c1") == :ok
      assert P.kinds_for(recs, "c1") == [:reserve]
    end

    test "concurrent calls under one budget never over-reserve past the cap" do
      cap = 300
      est = 100
      n = 10
      expected = div(cap, est)

      j = P.new_journal()
      p = P.new_provider()
      ctx = ctx(j, P.new_budget(cap))

      seed = seed()

      # The scheduler varies which calls win; the atomic budget fixes how
      # many fit the cap.
      results =
        1..n
        |> Task.async_stream(
          fn i -> SpendGate.around(ctx, "c#{i}", est, P.call_fun(p, "c#{i}", est)) end,
          max_concurrency: n,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      recs = P.records(j)
      ok_count = Enum.count(results, &match?({:ok, _}, &1))

      # actual == estimate here, so no refund frees budget mid-storm: exactly
      # `expected` reservations fit, and the peak reserved never exceeds the cap.
      assert P.reserved_within_cap(recs, cap) == :ok,
             "seed=#{seed}: over-reserved past cap #{cap}; records=#{inspect(recs)}"

      assert ok_count == expected,
             "seed=#{seed}: expected #{expected} successful reserves, got #{ok_count}"

      assert P.provider_calls(p) == expected,
             "seed=#{seed}: provider called #{P.provider_calls(p)}x, expected #{expected}"

      assert P.call_count(recs) == expected, "seed=#{seed}"
    end

    test "reserving the same cost_ref twice is rejected (no double-spend via retry)" do
      j = P.new_journal()
      ctx = ctx(j, P.new_budget(1000))

      assert {:ok, _reservation} = SpendGate.reserve(ctx, "c1", 100)
      # A second reserve for the SAME cost_ref must be rejected, not silently
      # accepted as a second independent reservation.
      assert {:error, _reason} = SpendGate.reserve(ctx, "c1", 100)

      recs = P.records(j)
      assert P.kinds_for(recs, "c1") == [:reserve]
    end

    test "settling the same reservation twice does not double-refund (token replay)" do
      j = P.new_journal()
      ctx = ctx(j, P.new_budget(1000))

      assert {:ok, reservation} = SpendGate.reserve(ctx, "c1", 100)
      assert :ok = SpendGate.settle(ctx, reservation, 70)
      # Replaying the same reservation token a second time must be rejected —
      # not silently refund estimate - actual a second time (money inflation).
      assert {:error, _reason} = SpendGate.settle(ctx, reservation, 70)

      recs = P.records(j)
      assert P.no_double_settle(recs) == :ok
    end
  end
end

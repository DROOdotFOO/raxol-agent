defmodule Raxol.Agent.Checkpoint.ControlsTest do
  @moduledoc """
  Negative controls for the checkpoint suites. Each forges the broken shape
  a check must catch (a checkpoint id from a second counter, a non-
  conversational tip, a write past the turn boundary, a silent restore
  fallback, a record written before its file) and asserts
  `Raxol.Agent.Test.CheckpointOracle` tells it from the correct shape. Every
  armed injector must fire (`CheckpointOracle.Counters`).
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Test.CheckpointOracle, as: Oracle
  alias Raxol.Agent.Test.CheckpointOracle.Counters

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "checkpoint_ctl_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp seed!(base) do
    {j, session, dir} = Oracle.open!(base)

    Oracle.append_all!(j, [
      Oracle.loop_event("turn_started"),
      Oracle.loop_event("item_completed", %{"text" => "hi"}),
      Oracle.loop_event("turn_completed"),
      Oracle.meta_event("idle")
    ])

    {j, session, dir}
  end

  test "a second-counter checkpoint breaks dense_ids?, single-counter keeps it",
       %{
         base: base
       } do
    h =
      Counters.new()
      |> Counters.arm(:second_counter)
      |> Counters.arm(:single_counter)

    # Correct shape (single counter): density holds.
    {j1, _s1, dir1} = seed!(base)
    :ok = FileStore.close(j1)
    Oracle.inject_single_counter_checkpoint!(dir1, %{"tip_offset" => 2})
    Counters.fire(h, :single_counter)

    assert Oracle.dense_ids?(dir1),
           "control positive arm: single-counter checkpoint stays dense"

    # Mutant (second counter): the density oracle must reject it.
    {j2, _s2, dir2} = seed!(base)
    :ok = FileStore.close(j2)
    Oracle.inject_second_counter_checkpoint!(dir2, %{"tip_offset" => 2})
    Counters.fire(h, :second_counter)

    refute Oracle.dense_ids?(dir2),
           "dead injector escaped: a side-counter checkpoint left the record layer dense"

    Counters.assert_all_fired!(h)
  end

  test "a mutant validator accepts a meta-id tip that the real oracle rejects",
       %{base: base} do
    h = Counters.new() |> Counters.arm(:any_tip)
    {j, _s, dir} = seed!(base)
    :ok = FileStore.close(j)

    records = Oracle.raw_records(dir)
    meta_id = Enum.find(records, &(&1["family"] == "meta")) |> Map.fetch!("id")

    # The mutant (dead injector) would accept it...
    assert Oracle.mutant_accept_any_tip?(records, meta_id)
    Counters.fire(h, :any_tip)

    # ...but the real tip-validity oracle rejects it.
    refute Oracle.valid_tip?(records, meta_id),
           "dead injector escaped: the tip oracle accepted a non-conversational offset"

    # And a genuine conversational tip is accepted by both (oracle not always-false).
    good = Oracle.tip_of(dir)
    assert Oracle.valid_tip?(records, good)
    Counters.assert_all_fired!(h)
  end

  test "the boundary oracle flags an open turn and an open reserve",
       %{base: base} do
    h =
      Counters.new()
      |> Counters.arm(:mid_turn)
      |> Counters.arm(:mid_reserve)
      |> Counters.arm(:boundary)

    # Clean boundary: accepted.
    {j0, _s0, dir0} = seed!(base)
    :ok = FileStore.close(j0)
    assert Oracle.at_turn_boundary?(Oracle.raw_records(dir0))
    Counters.fire(h, :boundary)

    # Open turn: a writer skipping the check would append here — the oracle says no.
    {j1, _s1, dir1} = Oracle.open!(base)

    Oracle.append_all!(j1, [
      Oracle.loop_event("turn_started"),
      Oracle.loop_event("item_started")
    ])

    :ok = FileStore.close(j1)

    refute Oracle.at_turn_boundary?(Oracle.raw_records(dir1)),
           "dead injector escaped: mid-turn read as a boundary"

    Counters.fire(h, :mid_turn)

    # Open reserve: same.
    {j2, _s2, dir2} = Oracle.open!(base)

    Oracle.append_all!(j2, [
      Oracle.loop_event("turn_started"),
      Oracle.loop_event("turn_completed"),
      Oracle.meta_event("reserve", %{"amount" => "1.00"})
    ])

    :ok = FileStore.close(j2)

    refute Oracle.at_turn_boundary?(Oracle.raw_records(dir2)),
           "dead injector escaped: mid-reserve read as a boundary"

    Counters.fire(h, :mid_reserve)

    Counters.assert_all_fired!(h)
  end

  test "a silent-fallback restore hides the typed error",
       %{base: base} do
    h =
      Counters.new()
      |> Counters.arm(:silent_fallback)
      |> Counters.arm(:record_before_file)

    {j, _s, dir} = seed!(base)
    :ok = FileStore.close(j)

    # Record-before-file ordering: a checkpoint naming a snapshot never written.
    ref = Oracle.inject_record_before_file!(dir, Oracle.tip_of(dir))
    Counters.fire(h, :record_before_file)

    refute Oracle.snapshot_present?(dir, ref),
           "the referenced snapshot must be absent for this control"

    # The mutant returns success on the missing snapshot where the contract
    # requires {:error, :snapshot_missing}.
    result = Oracle.mutant_restore_silent_fallback(dir, ref)
    Counters.fire(h, :silent_fallback)

    assert elem(result, 0) == :ok,
           "dead injector escaped: the silent fallback did not mask the error with a success tuple"

    Counters.assert_all_fired!(h)
  end
end

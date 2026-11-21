defmodule Raxol.Agent.Checkpoint.RecordTest do
  @moduledoc """
  Checkpoint pointer records (`Raxol.Agent.Journal.Records.Checkpoint`)
  through the real Writer and FileStore. Journal truth comes from the raw
  decoder in `Raxol.Agent.Test.CheckpointOracle`, never `FileStore.read/2`.

  A checkpoint takes one dense offset, writes its snapshot file before its
  record, restores to the same model as a full fold, may be tip-only, is
  verified by sha256 at restore, refuses an invalid tip or a mid-turn or
  mid-reserve journal without appending, and carries only a pointer and a
  hash. GC low-watermark density is not covered.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.Test.CheckpointOracle, as: Oracle

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "checkpoint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "write/3 consumes exactly one journal offset" do
    test "write appends one checkpoint record; record-layer ids stay dense 1..n+1",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      before_ids = Oracle.raw_ids(dir)
      tip = Oracle.tip_of(dir)

      assert tip == 3,
             "tip is the last CONVERSATIONAL record (turn_completed), not the idle tail"

      # The offset returned is the checkpoint's own (last + 1).
      assert {:ok, offset} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      assert offset == List.last(before_ids) + 1

      assert Oracle.dense_ids?(dir),
             "record ids must stay dense after the checkpoint append"

      records = Oracle.raw_records(dir)
      cp = Enum.find(records, &(&1["kind"] == "checkpoint"))
      assert cp["id"] == offset
      assert cp["tip_offset"] == tip
      :ok = FileStore.close(j)
    end

    test "the checkpoint is stamped kind=\"checkpoint\" and rides the SAME single Writer",
         %{
           base: base
         } do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => []}, reason: "auto")

      # Appended through the single Writer's offset space, not a side counter.
      cps = Oracle.raw_records(dir) |> Enum.filter(&(&1["kind"] == "checkpoint"))
      assert length(cps) == 1
      assert Oracle.dense_ids?(dir)
      :ok = FileStore.close(j)
    end
  end

  describe "the snapshot file is written before the record" do
    test "orphan snapshot file + NO record = harmless: journal healthy, restore ignores it",
         %{
           base: base
         } do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # A crash AFTER the snapshot file write but BEFORE the record append leaves
      # a content-addressed orphan. It is never deleted implicitly.
      {_ref, _hash} = Oracle.stage_snapshot!(dir, %{"applied" => [1, 2, 3]})

      assert FileStore.status(j) == :ok,
             "an orphan snapshot must not damage the journal"

      assert Oracle.dense_ids?(dir)

      # No checkpoint record exists, so restore must fall back cleanly.
      assert {:error, :no_checkpoint} = Checkpoint.restore(j),
             "with no checkpoint record, restore reports no checkpoint (never reads the orphan)"

      :ok = FileStore.close(j)
    end

    test "record present + snapshot file ABSENT surfaces at restore; journal stays :ok, nothing deleted",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      tip = Oracle.tip_of(dir)

      # The ILLEGAL order made permanent: a checkpoint record that names a
      # snapshot which was never written.
      ref = Oracle.inject_record_before_file!(dir, tip)
      refute Oracle.snapshot_present?(dir, ref)
      segs_before = File.ls!(Path.join(dir, "journal"))

      assert {:error, :snapshot_missing} = Checkpoint.restore(j),
             "a referenced-but-absent snapshot must surface :snapshot_missing"

      # Checkpoint-level damage is NOT journal damage.
      assert FileStore.status(j) == :ok

      assert File.ls!(Path.join(dir, "journal")) == segs_before,
             "nothing deleted"

      :ok = FileStore.close(j)
    end
  end

  describe "restore/2 round-trip" do
    # Expressed against the oracle's fold, which stands in for a snapshot
    # codec; the round-trip equation is exact.
    test "restore equals a full fold; equals fold(0..tip) then fold-forward the mutation tail",
         %{
           base: base
         } do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      tip = Oracle.tip_of(dir)

      # Checkpoint captures the model as of the tip.
      assert {:ok, _cp_off} =
               Checkpoint.write(j, Oracle.fold(Oracle.raw_records(dir)), reason: "manual")

      # Mutate the conversation forward past the checkpoint.
      Oracle.append_all!(j, [
        Oracle.loop_event("turn_started"),
        Oracle.loop_event("item_completed", %{"text" => "more"}),
        Oracle.loop_event("turn_completed")
      ])

      all = Oracle.raw_records(dir)
      full = Oracle.fold(all)

      # The restore identity, computed independently by the oracle:
      #   restore == load(snapshot at tip) ⊕ fold-forward(events with id > tip)
      #           == fold(all)  (a full fold over the persistent slice)
      {events_le_tip, events_gt_tip} = Enum.split_with(all, &(&1["id"] <= tip))
      snapshot = Oracle.load(Oracle.dump(Oracle.fold(events_le_tip)))
      reconstructed = Oracle.fold_forward(snapshot, events_gt_tip)

      assert reconstructed == full,
             "oracle sanity: the ⊕ identity must hold (non-vacuous round-trip)"

      # The subject under test must reproduce exactly that model.
      assert {:ok, ^full} = Checkpoint.restore(j),
             "restore must equal the full fold on the persistent slice"

      :ok = FileStore.close(j)
    end
  end

  describe "a tip-only checkpoint (snapshot_ref nil)" do
    test "a nil-snapshot checkpoint is legal and restore falls back to fold(0..tip_offset)",
         %{
           base: base
         } do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      tip = Oracle.tip_of(dir)

      # snapshot: nil -> tip-only pointer (legal).
      assert {:ok, _off} = Checkpoint.write(j, nil, reason: "manual"),
             "tip-only checkpoint (nil snapshot) must be accepted"

      cp = Oracle.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))

      assert cp["snapshot_ref"] == nil,
             "tip-only pointer carries snapshot_ref: nil"

      assert cp["snapshot_hash"] == nil

      expected = Oracle.fold(Enum.filter(Oracle.raw_records(dir), &(&1["id"] <= tip)))

      assert {:ok, ^expected} = Checkpoint.restore(j),
             "with no snapshot, restore is a full fold(0..tip_offset)"

      :ok = FileStore.close(j)
    end
  end

  describe "snapshot hash verification at restore" do
    test "sha256(bytes) == snapshot_hash for a healthy checkpoint", %{
      base: base
    } do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      cp = Oracle.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
      assert is_binary(cp["snapshot_ref"]) and is_binary(cp["snapshot_hash"])
      bytes = File.read!(Path.join(dir, cp["snapshot_ref"]))

      assert Oracle.sha256_hex(bytes) == cp["snapshot_hash"],
             "snapshot_hash must be the lowercase-hex sha256 of the file bytes"

      :ok = FileStore.close(j)
    end

    test "a corrupted snapshot file → :snapshot_corrupt at restore; journal :ok, nothing deleted",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      cp = Oracle.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
      snap_path = Path.join(dir, cp["snapshot_ref"])

      # Flip the snapshot bytes so sha256 no longer matches snapshot_hash.
      File.write!(snap_path, File.read!(snap_path) <> "corruption")

      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "a hash mismatch must surface :snapshot_corrupt"

      assert FileStore.status(j) == :ok,
             "checkpoint damage is not journal damage"

      assert File.exists?(snap_path), "nothing deleted on corruption"
      :ok = FileStore.close(j)
    end
  end

  describe "tip_offset validation at write" do
    test "tip_offset naming a META event → :invalid_tip; offset counter untouched",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      before_ids = Oracle.raw_ids(dir)

      # id 5 is the trailing meta `idle` — not CONVERSATIONAL.
      meta_id =
        Oracle.raw_records(dir)
        |> Enum.find(&(&1["family"] == "meta"))
        |> Map.fetch!("id")

      refute Oracle.valid_tip?(Oracle.raw_records(dir), meta_id),
             "oracle: meta id is not a valid tip"

      assert {:error, :invalid_tip} =
               Checkpoint.write(j, %{"applied" => []}, tip_offset: meta_id),
             "a tip_offset pointing at a meta event must be rejected"

      assert Oracle.raw_ids(dir) == before_ids, "nothing appended on :invalid_tip"

      # The offset counter is untouched: the next real append continues densely.
      {:ok, next} = FileStore.append(j, Oracle.loop_event("turn_started"))
      assert next == List.last(before_ids) + 1
      :ok = FileStore.close(j)
    end

    test "tip_offset naming ANOTHER checkpoint → :invalid_tip", %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # Stage a prior checkpoint (single-counter) so its offset exists to point at.
      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => Oracle.tip_of(dir),
        "snapshot_ref" => nil,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      cp_id =
        Oracle.raw_records(dir)
        |> Enum.find(&(&1["kind"] == "checkpoint"))
        |> Map.fetch!("id")

      refute Oracle.valid_tip?(Oracle.raw_records(dir), cp_id)

      assert {:error, :invalid_tip} =
               Checkpoint.write(j, %{"applied" => []}, tip_offset: cp_id),
             "a tip_offset pointing at a checkpoint record must be rejected"

      :ok = FileStore.close(j)
    end

    test "tip_offset naming a HOLE (beyond last offset) → :invalid_tip; nothing appended",
         %{
           base: base
         } do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      before_ids = Oracle.raw_ids(dir)
      hole = List.last(before_ids) + 99

      assert {:error, :invalid_tip} =
               Checkpoint.write(j, %{"applied" => []}, tip_offset: hole)

      assert Oracle.raw_ids(dir) == before_ids, "nothing appended on a hole tip"
      :ok = FileStore.close(j)
    end
  end

  describe "checkpoints never land mid-turn or mid-reserve" do
    test "mid-turn (turn_started with no close) → :mid_turn; nothing appended",
         %{base: base} do
      {j, _session, dir} = Oracle.open!(base)

      Oracle.append_all!(j, [
        Oracle.loop_event("turn_started"),
        Oracle.loop_event("item_started")
      ])

      before_ids = Oracle.raw_ids(dir)

      refute Oracle.at_turn_boundary?(Oracle.raw_records(dir)),
             "oracle: an open turn is not a boundary"

      assert {:error, :mid_turn} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual"),
             "a checkpoint between turn_started and its close must be rejected"

      assert Oracle.raw_ids(dir) == before_ids, "nothing appended mid-turn"
      :ok = FileStore.close(j)
    end

    test "mid-reserve (spend-gate reserve with no terminal) → :mid_reserve; nothing appended",
         %{
           base: base
         } do
      {j, _session, dir} = Oracle.open!(base)

      Oracle.append_all!(j, [
        Oracle.loop_event("turn_started"),
        Oracle.loop_event("turn_completed"),
        Oracle.meta_event("reserve", %{"amount" => "1.00"})
      ])

      before_ids = Oracle.raw_ids(dir)

      refute Oracle.at_turn_boundary?(Oracle.raw_records(dir)),
             "oracle: an open reserve is not a boundary"

      assert {:error, :mid_reserve} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual"),
             "a checkpoint between a reserve and its terminal must be rejected"

      assert Oracle.raw_ids(dir) == before_ids, "nothing appended mid-reserve"
      :ok = FileStore.close(j)
    end
  end

  describe "the record body is a pointer and a hash" do
    test "the record carries only frozen keys — no model/messages/tools content",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # A model deliberately laden with secret-looking keys — none may reach the record.
      model = %{
        "applied" => [1, 2, 3],
        "messages" => ["secret"],
        "tools" => ["hammer"],
        "api_key" => "sk-xxx"
      }

      assert {:ok, _off} = Checkpoint.write(j, model, reason: "manual")

      cp = Oracle.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
      allowed = MapSet.new(Checkpoint.record_keys())

      assert MapSet.subset?(MapSet.new(Map.keys(cp)), allowed),
             "checkpoint record grew keys outside the frozen set: #{inspect(Map.keys(cp))}"

      refute Map.has_key?(cp, "messages")
      refute Map.has_key?(cp, "api_key")
      :ok = FileStore.close(j)
    end

    test "the written record carries branch_id — the frozen field @type t now documents",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual")

      cp = Oracle.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))

      # branch_id is written (single linear "main" branch, v1) and enumerated by
      # record_keys/0 — the @type t spec must include it too (spec/record parity).
      assert cp["branch_id"] == "main"
      assert "branch_id" in Checkpoint.record_keys()
      :ok = FileStore.close(j)
    end
  end

  describe "reason enum" do
    test "manual / compaction / auto are all accepted at write", %{base: base} do
      for reason <- ~w(manual compaction auto) do
        {j, _session, dir} = Oracle.seed_conversation!(base)

        assert {:ok, _off} =
                 Checkpoint.write(j, %{"applied" => []}, reason: reason),
               "reason #{reason} must be accepted"

        cp = Oracle.raw_records(dir) |> Enum.find(&(&1["kind"] == "checkpoint"))
        assert cp["reason"] == reason
        :ok = FileStore.close(j)
      end
    end

    test "an unknown reason is TOLERATED on READ (forward-compat) — journal healthy, restore works",
         %{base: base} do
      {j, session, dir} = Oracle.seed_conversation!(base)
      {ref, hash} = Oracle.stage_snapshot!(dir, %{"applied" => [1, 2, 3]})

      # A checkpoint written by a FUTURE producer with a reason this version has
      # never seen. The reader seam tolerates it (never errors, never damages).
      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => Oracle.tip_of(dir),
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "future_reason_v9"
      })

      log =
        capture_log(fn ->
          assert {:ok, records} = FileStore.read(j)
          cp = Enum.find(records, &(&1["kind"] == "checkpoint"))

          assert cp["reason"] == "future_reason_v9",
                 "unknown reason preserved raw"
        end)

      # capture_log/1 collects Logger events from EVERY process while it runs,
      # and async siblings corrupt their own journals on purpose — so only a
      # corruption alarm naming a segment of THIS session's dir counts.
      own_dir = FileStore.session_dir(session, base_dir: base) <> "/"

      own_alarms =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "corruption" and String.contains?(&1, own_dir)))

      assert own_alarms == [], "an unknown reason must not flag this journal corrupt"
      assert FileStore.status(j) == :ok

      # Restore must still work off a checkpoint whose reason is unknown.
      assert {:ok, %{"applied" => [1, 2, 3]}} = Checkpoint.restore(j),
             "an unknown reason must not block restore (read-side tolerance)"

      :ok = FileStore.close(j)
    end
  end
end

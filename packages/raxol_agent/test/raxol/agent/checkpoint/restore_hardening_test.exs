defmodule Raxol.Agent.Checkpoint.RestoreHardeningTest do
  @moduledoc """
  Checkpoint restore against hostile or damaged disk state: every case is a
  typed rejection, never a raise. Also covers the surrogate-codec guard,
  `protected_floor/1,2`, and the atomic turn-boundary check in the Writer.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.CheckpointOracle, as: Oracle
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "checkpoint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "restore of a non-map snapshot" do
    test "a hash-matched snapshot decoding to a LIST → :snapshot_corrupt (no BadMapError), with a non-empty conversational tail",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # A non-empty CONVERSATIONAL tail past the frozen tip (id 3): ids 5,6,7.
      # These are exactly the records restore folds FORWARD onto the snapshot, so
      # the snapshot must be a map or `fold_step`'s `Map.update` raises.
      Oracle.append_all!(j, [
        Oracle.loop_event("turn_started"),
        Oracle.loop_event("item_completed", %{"text" => "more"}),
        Oracle.loop_event("turn_completed")
      ])

      # An adversarial snapshot whose top-level term is a LIST, not the folded
      # model map — staged with a MATCHING content hash so it clears sha256
      # verification and reaches the decoder.
      {ref, hash} = Oracle.stage_snapshot!(dir, [1, 2, 3])

      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      # BEFORE the fix this reached `fold_step` and raised BadMapError; the
      # contract demands a typed reject with the journal left intact.
      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "a non-map snapshot top-level must surface :snapshot_corrupt, never raise"

      assert FileStore.status(j) == :ok,
             "a corrupt snapshot is not journal damage"

      :ok = FileStore.close(j)
    end

    test "a hash-matched snapshot decoding to a SCALAR → :snapshot_corrupt (no raise)",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      Oracle.append_all!(j, [
        Oracle.loop_event("turn_started"),
        Oracle.loop_event("turn_completed")
      ])

      # Top-level scalar (a bare integer) — same class, different shape.
      {ref, hash} = Oracle.stage_snapshot!(dir, 42)

      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "a scalar snapshot top-level must surface :snapshot_corrupt, never raise"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end
  end

  describe "restore of a checkpoint record missing keys" do
    test "a checkpoint missing tip_offset → :malformed_checkpoint (no KeyError)",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # A truncated checkpoint the tolerant Reader accepts but restore must not
      # blindly `fetch!` — no `tip_offset`.
      Oracle.inject_single_counter_checkpoint!(dir, %{
        "snapshot_ref" => nil,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      assert {:error, :malformed_checkpoint} = Checkpoint.restore(j),
             "a checkpoint missing tip_offset must surface a typed reject, never raise"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "a checkpoint with tip_offset: null → :malformed_checkpoint, not a fold that drops the tail",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      {ref, hash} = Oracle.stage_snapshot!(dir, %{"applied" => []})

      # Present but nil: `id > nil` is false for every id, so an unguarded
      # restore would fold nothing forward onto the snapshot.
      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => nil,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      assert {:error, :malformed_checkpoint} = Checkpoint.restore(j),
             "a nil tip_offset must surface a typed reject"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "a checkpoint missing snapshot_ref → :malformed_checkpoint (no KeyError)",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # No `snapshot_ref` key at all — the tip-only clause head needs it present
      # as nil, and the snapshot clause `fetch!`es it; both would blow up.
      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      assert {:error, :malformed_checkpoint} = Checkpoint.restore(j),
             "a checkpoint missing snapshot_ref must surface a typed reject, never raise"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "a checkpoint missing id → typed error, newest selection never raises",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # Raw-appended (bypassing the Writer's id stamp) so the record carries NO
      # `id`. `newest_checkpoint`'s `max_by(fetch! "id")` would have KeyError'd;
      # in practice the tolerant Reader is STRICTER on `id` than on the pointer
      # fields — a missing offset breaks density, so the read surfaces
      # `{:journal, :damaged}` (nothing deleted) before restore ever selects.
      # Either way the guarantee holds: a TYPED error, never an unhandled raise.
      Oracle.raw_append!(dir, %{
        "kind" => "checkpoint",
        "schema_version" => "1.0.0",
        "tip_offset" => 3,
        "snapshot_ref" => nil,
        "snapshot_hash" => nil,
        "reason" => "manual"
      })

      assert {:error, reason} = Checkpoint.restore(j),
             "a checkpoint missing id must surface a typed reject, never raise"

      assert reason in [:malformed_checkpoint, {:journal, :damaged}],
             "unexpected reason: #{inspect(reason)}"

      # Nothing deleted on the damaged read.
      assert File.ls!(Path.join(dir, "journal")) != []
      :ok = FileStore.close(j)
    end
  end

  describe "restore of a snapshot_ref outside the snapshot store" do
    for {label, hostile_ref} <- [
          {"path traversal", "snapshots/../../../../etc/passwd"},
          {"non-hex name", "snapshots/not-a-sha.json"},
          {"bare traversal", "../secrets.json"}
        ] do
      test "a #{label} ref → :malformed_pointer on restore and restore_checkpoint; floor skips it",
           %{base: base} do
        {j, dir, older, healthy} = Oracle.two_checkpoints!(base)

        # The hostile record claims the older tip, so a floor that took it
        # would differ from the healthy one.
        assert older["tip_offset"] < healthy["tip_offset"]

        Oracle.inject_single_counter_checkpoint!(dir, %{
          "tip_offset" => older["tip_offset"],
          "snapshot_ref" => unquote(hostile_ref),
          "snapshot_hash" => String.duplicate("a", 64),
          "reason" => "manual"
        })

        assert {:error, :malformed_pointer} = Checkpoint.restore(j),
               "a hostile ref must be refused, never joined onto the session dir"

        {:ok, records} = FileStore.read(j)
        hostile = List.last(records)
        assert hostile["snapshot_ref"] == unquote(hostile_ref)

        assert {:error, :malformed_pointer} =
                 Checkpoint.restore_checkpoint(j, records, hostile)

        # The hostile newest is unhealthy, so the floor is the checkpoint
        # beneath it.
        assert Checkpoint.protected_floor(j, records) ==
                 {:offset, healthy["tip_offset"]}

        assert FileStore.status(j) == :ok
        :ok = FileStore.close(j)
      end
    end
  end

  describe "write/3 with a model the surrogate codec cannot round-trip" do
    test "a model carrying a pid and a tuple → :surrogate_backend_unbound; nothing appended, nothing staged",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)
      before_ids = Oracle.raw_ids(dir)

      # A typical folded harness model: structs/tuples/pids everywhere. BEFORE
      # the fix `dump/1` was `Jason.encode!/1` — an uncaught raise inside
      # `stage_snapshot` crashing the caller.
      model = %{"owner" => self(), "shape" => {:grid, 80, 24}}

      assert {:error, :surrogate_backend_unbound} =
               Checkpoint.write(j, model, reason: "manual"),
             "a non-JSON model must surface a typed error, never a Jason raise"

      assert Oracle.raw_ids(dir) == before_ids, "nothing may be appended"

      assert File.ls!(Path.join(dir, "snapshots")) == [],
             "nothing may be staged for a rejected model"

      :ok = FileStore.close(j)
    end

    test "an atom-keyed model (decode(encode(m)) ≠ m — a silently mangled restore) → typed reject too",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # Jason ENCODES this fine — but it restores string-keyed, so a surrogate
      # snapshot of it can never restore what was written. Corruption by
      # construction; the guard must reject at write.
      assert {:error, :surrogate_backend_unbound} =
               Checkpoint.write(j, %{applied: [1, 2, 3]}, reason: "manual")

      assert File.ls!(Path.join(dir, "snapshots")) == []
      :ok = FileStore.close(j)
    end
  end

  describe "surrogate restores are marked" do
    test "write and restore emit the [:raxol,:agent,:journal,:checkpoint,:surrogate] marker; restore logs a warning",
         %{base: base} do
      {j, _session, _dir} = Oracle.seed_conversation!(base)

      handler = "checkpoint-surrogate-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler,
          [:raxol, :agent, :journal, :checkpoint, :surrogate],
          fn _event, _meas, meta, _cfg -> send(parent, {:surrogate, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _off} =
               Checkpoint.write(j, %{"applied" => [1, 2, 3]}, reason: "manual")

      assert_receive {:surrogate, %{op: :write}},
                     100,
                     "staging a surrogate snapshot must be marked at runtime"

      log =
        capture_log(fn ->
          assert {:ok, %{"applied" => [1, 2, 3]}} = Checkpoint.restore(j)
        end)

      assert_receive {:surrogate, %{op: :restore, tip_offset: 3} = meta},
                     100,
                     "a surrogate restore must be marked at runtime"

      # The marker carries offsets and the session only, never model content.
      refute Map.has_key?(meta, :model)

      assert log =~ "SURROGATE",
             "a surrogate restore must warn — the model is the surrogate fold, not real state"

      :ok = FileStore.close(j)
    end
  end

  describe "restore bounds nesting before parsing" do
    test "a small ~100k-deep hash-valid snapshot → :snapshot_corrupt, no raise, journal :ok",
         %{base: base} do
      {j, _session, dir} = Oracle.seed_conversation!(base)

      # ~200 KB of bytes, ~100k levels of nesting: passes the 64 MiB size cap
      # and the sha256 check, and BEFORE the fix reached `Jason.decode/1`,
      # which materializes the entire term before any post-hoc depth walk.
      deep =
        String.duplicate("[", 100_000) <> "1" <> String.duplicate("]", 100_000)

      bytes = ~s({"applied":) <> deep <> "}"
      hash = Oracle.sha256_hex(bytes)
      ref = "snapshots/#{hash}.json"
      File.mkdir_p!(Path.join(dir, "snapshots"))
      File.write!(Path.join(dir, ref), bytes)

      Oracle.inject_single_counter_checkpoint!(dir, %{
        "tip_offset" => 3,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => "manual"
      })

      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j),
             "adversarial nesting must surface the promised typed reject"

      assert FileStore.status(j) == :ok
      :ok = FileStore.close(j)
    end

    test "the pre-decode byte scan: over-bound nesting rejected without building a term; brackets inside JSON strings are content",
         %{base: _base} do
      alias Raxol.Agent.Journal.Records.Checkpoint.FileBackend

      # Over the @max_decode_depth 64 bound (65 arrays inside a map = 66 deep).
      deep = String.duplicate("[", 65) <> "1" <> String.duplicate("]", 65)
      refute FileBackend.nesting_within_bound?(~s({"applied":) <> deep <> "}")

      # A real snapshot shape passes.
      assert FileBackend.nesting_within_bound?(~s({"applied":[1,2,3]}))

      # Brackets INSIDE a JSON string are content, not nesting — the scan must
      # not false-positive a legit snapshot whose text contains brackets.
      brackets = String.duplicate("[", 500)
      assert FileBackend.nesting_within_bound?(~s({"a":") <> brackets <> ~s("}))

      # ... including behind an escaped quote.
      assert FileBackend.nesting_within_bound?(~s({"a":"x\\"[[[[["}))
    end
  end

  describe "protected_floor/1 with malformed checkpoints" do
    test "a checkpoint record missing id → {:offset, 1} (whole journal protected), no KeyError" do
      records = [
        %{"id" => 1, "family" => "loop", "type" => "turn_started"},
        %{"kind" => "checkpoint", "tip_offset" => 3}
      ]

      # BEFORE the fix: Enum.max_by(&Map.fetch!(&1, "id")) → KeyError, crashing
      # the GC admission check that exists to prevent orphaning.
      assert Checkpoint.protected_floor(records) == {:offset, 1}
    end

    test "a checkpoint record missing tip_offset → {:offset, 1}, no KeyError" do
      records = [%{"id" => 5, "kind" => "checkpoint"}]
      assert Checkpoint.protected_floor(records) == {:offset, 1}
    end

    test "a checkpoint with non-integer id/tip_offset junk → {:offset, 1}" do
      assert Checkpoint.protected_floor([
               %{"id" => 5, "kind" => "checkpoint", "tip_offset" => "3"}
             ]) == {:offset, 1}

      assert Checkpoint.protected_floor([
               %{"id" => "5", "kind" => "checkpoint", "tip_offset" => 3}
             ]) == {:offset, 1}
    end

    test "healthy checkpoints → the NEWEST checkpoint's tip; none → :none" do
      cps = [
        %{"id" => 5, "kind" => "checkpoint", "tip_offset" => 3},
        %{"id" => 9, "kind" => "checkpoint", "tip_offset" => 7}
      ]

      assert Checkpoint.protected_floor(cps) == {:offset, 7}
      assert Checkpoint.protected_floor([]) == :none
    end
  end

  describe "protected_floor/2" do
    test "healthy newest → the newest checkpoint's tip", %{base: base} do
      {j, _dir, older, newer} = Oracle.two_checkpoints!(base)
      {:ok, records} = FileStore.read(j)

      assert newer["tip_offset"] > older["tip_offset"]

      assert Checkpoint.protected_floor(j, records) ==
               {:offset, newer["tip_offset"]}

      :ok = FileStore.close(j)
    end

    test "corrupt newest + healthy older → the OLDER healthy tip", %{base: base} do
      {j, dir, older, newer} = Oracle.two_checkpoints!(base)
      Oracle.corrupt_snapshot!(dir, newer["snapshot_ref"])
      {:ok, records} = FileStore.read(j)

      # The record-only arity cannot see snapshot health and keeps the corrupt
      # newest's higher tip; truncating up to it would cut records the older
      # checkpoint's restore still folds.
      assert Checkpoint.protected_floor(records) ==
               {:offset, newer["tip_offset"]}

      assert Checkpoint.protected_floor(j, records) ==
               {:offset, older["tip_offset"]},
             "the floor must be the newest healthy checkpoint's tip, not the corrupt newest's"

      # The floor names a checkpoint that restores; the newest does not.
      assert {:error, :snapshot_corrupt} = Checkpoint.restore(j)
      assert {:ok, _model} = Checkpoint.restore_checkpoint(j, records, older)

      :ok = FileStore.close(j)
    end

    test "no checkpoint at all → :none", %{base: base} do
      {j, _session, _dir} = Oracle.seed_conversation!(base)
      {:ok, records} = FileStore.read(j)

      assert Checkpoint.protected_floor(j, records) == :none

      :ok = FileStore.close(j)
    end

    test "every checkpoint corrupt → :none (nothing healthy to protect)", %{
      base: base
    } do
      {j, dir, older, newer} = Oracle.two_checkpoints!(base)
      Oracle.corrupt_snapshot!(dir, older["snapshot_ref"])
      Oracle.corrupt_snapshot!(dir, newer["snapshot_ref"])
      {:ok, records} = FileStore.read(j)

      assert Checkpoint.protected_floor(j, records) == :none

      :ok = FileStore.close(j)
    end
  end

  describe "the turn-boundary check and the append are one Writer step" do
    test "append_checked validates against the FRESHEST records; a failing check appends nothing",
         %{base: base} do
      {j, _session, dir} = Oracle.open!(base)
      Oracle.append_all!(j, [Oracle.loop_event("turn_started")])
      before_ids = Oracle.raw_ids(dir)

      check = fn records ->
        if Oracle.at_turn_boundary?(records), do: :ok, else: {:error, :mid_turn}
      end

      cp = %{"kind" => "checkpoint", "tip_offset" => 1, "reason" => "manual"}

      assert {:error, :mid_turn} = FileStore.append_checked(j, cp, check)

      assert Oracle.raw_ids(dir) == before_ids,
             "a rejected checked append appends nothing"

      # Close the turn → the same append is admitted, dense offset consumed.
      Oracle.append_all!(j, [Oracle.loop_event("turn_completed")])
      assert {:ok, off} = FileStore.append_checked(j, cp, check)
      assert off == List.last(Oracle.raw_ids(dir))
      assert Oracle.dense_ids?(dir)
      :ok = FileStore.close(j)
    end

    test "a raising check fails CLOSED and the Writer survives", %{base: base} do
      {j, _session, _dir} = Oracle.open!(base)

      assert {:error, {:check_raised, _}} =
               FileStore.append_checked(j, %{"kind" => "checkpoint"}, fn _ ->
                 raise "boom"
               end)

      # The Writer must not have crashed out from under the session.
      assert {:ok, _} = FileStore.append(j, Oracle.loop_event("turn_started"))
      :ok = FileStore.close(j)
    end

    test "concurrent turn traffic through a shared joiner handle: no checkpoint ever lands mid-turn",
         %{base: base} do
      {j, session, dir} = Oracle.seed_conversation!(base)

      # A second handle joining the same Writer.
      {:ok, j2} = FileStore.open(session, base_dir: base)

      turns =
        Task.async(fn ->
          for _ <- 1..40 do
            {:ok, _} = FileStore.append(j2, Oracle.loop_event("turn_started"))
            {:ok, _} = FileStore.append(j2, Oracle.loop_event("turn_completed"))
          end

          :ok
        end)

      # Interleaved checkpoint writes: each either lands at a boundary or
      # typed-rejects (:mid_turn) — never lands mid-turn.
      for _ <- 1..40 do
        case Checkpoint.write(j, %{"applied" => []}, reason: "auto") do
          {:ok, _} -> :ok
          {:error, :mid_turn} -> :ok
          other -> flunk("unexpected write result: #{inspect(other)}")
        end
      end

      assert :ok = Task.await(turns)

      # After the dust settles a write at the boundary must still land.
      assert {:ok, _} =
               Checkpoint.write(j, %{"applied" => []}, reason: "manual")

      # The raw-journal invariant: for EVERY checkpoint record, the records
      # before it sit at a turn boundary (open-turn balance zero).
      records = Oracle.raw_records(dir)

      records
      |> Enum.with_index()
      |> Enum.each(fn {r, i} ->
        if r["kind"] == "checkpoint" do
          prefix = Enum.take(records, i)

          assert Oracle.at_turn_boundary?(prefix),
                 "checkpoint at offset #{r["id"]} landed mid-turn"
        end
      end)

      assert Oracle.dense_ids?(dir)
      :ok = FileStore.close(j2)
      :ok = FileStore.close(j)
    end
  end
end

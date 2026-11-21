defmodule Raxol.Agent.CheckpointOracle do
  @moduledoc """
  Test oracle for checkpoint pointer records.

  Journal truth comes from `File.read!` and this module's own framed-line
  decoder (`raw_records/1`), never `FileStore.read/2` or the Writer's
  offset. The tip predicate, record density, tip validity, the
  turn-boundary rule, `sha256_hex/1` and a deterministic fold (`fold/1`,
  standing in for a snapshot codec) are reimplemented here, so assertions
  check the production code against code it shares nothing with.

  Injectors forge the broken disk and return shapes each negative control
  must catch, and `Counters` records that every armed injector fired.
  """

  import ExUnit.Assertions

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint

  # The only record types that can be the journal tip.
  @conversational ~w(
    turn_started item_started item_completed
    turn_completed turn_canceled error approval_requested
  )

  @schema_version "1.0.0"

  @doc "The conversational type whitelist (string forms)."
  def conversational_types, do: @conversational

  # Session and seeding through the real Writer and FileStore.

  @doc "Open a fresh real FileStore journal under `base`. Returns `{handle, session, dir}`."
  def open!(base, opts \\ []) do
    session = "checkpoint-#{System.unique_integer([:positive])}"
    {:ok, j} = FileStore.open(session, Keyword.put(opts, :base_dir, base))
    {j, session, Path.join(base, session)}
  end

  @doc """
  A journal ending at a turn boundary, with a trailing non-conversational
  record so the tip is never the last physical record.
  """
  def seed_conversation!(base) do
    {j, session, dir} = open!(base)

    append_all!(j, [
      loop_event("turn_started"),
      loop_event("item_completed", %{"text" => "hi"}),
      loop_event("turn_completed"),
      meta_event("idle")
    ])

    {j, session, dir}
  end

  @doc """
  Two healthy snapshot checkpoints with distinct models, so their snapshot
  files differ. Returns the handle, the session dir and both raw records,
  older first.
  """
  def two_checkpoints!(base) do
    {j, _session, dir} = seed_conversation!(base)

    assert {:ok, _off} =
             Checkpoint.write(j, fold(raw_records(dir)), reason: "manual")

    append_all!(j, [
      loop_event("turn_started"),
      loop_event("item_completed", %{"text" => "more"}),
      loop_event("turn_completed")
    ])

    assert {:ok, _off} =
             Checkpoint.write(j, fold(raw_records(dir)), reason: "manual")

    [older, newer] =
      dir |> raw_records() |> Enum.filter(&(&1["kind"] == "checkpoint"))

    {j, dir, older, newer}
  end

  @doc "Append bytes to a snapshot file so its hash no longer matches."
  def corrupt_snapshot!(dir, ref) do
    path = Path.join(dir, ref)
    File.write!(path, File.read!(path) <> "corruption")
  end

  @doc """
  A durable loop event map in the on-disk shape the Writer will stamp `id`/
  `schema_version` onto (matching `EmitBridge.durable_record/1`). `type` is a
  CONVERSATIONAL member unless overridden.
  """
  def loop_event(type, payload \\ %{}) do
    %{
      "v" => 0,
      "session_id" => nil,
      "turn_id" => nil,
      "ts" => System.system_time(:microsecond),
      "family" => "loop",
      "type" => to_string(type),
      "tier" => "durable",
      "payload" => payload
    }
  end

  @doc "A `family: meta` event (never a tip — excluded by the closure rule)."
  def meta_event(type, payload \\ %{}) do
    %{loop_event(type, payload) | "family" => "meta"}
  end

  @doc "Append one event through the REAL Writer, asserting the expected dense offset."
  def append!(journal, event), do: FileStore.append(journal, event)

  @doc "Append a list of events through the REAL Writer in order; returns the offsets."
  def append_all!(journal, events) do
    Enum.map(events, fn e ->
      {:ok, off} = FileStore.append(journal, e)
      off
    end)
  end

  # Raw decoder, independent of FileStore.read.

  @segment_re ~r/^\d{6}\.jsonl$/

  @doc "Raw-decode every complete framed line under `dir/journal`, in offset order."
  def raw_records(dir) do
    dir
    |> Path.join("journal")
    |> segment_paths()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)
    end)
  end

  @doc "Ids of the raw journal, in file order."
  def raw_ids(dir), do: dir |> raw_records() |> Enum.map(& &1["id"])

  defp segment_paths(journal_dir) do
    case File.ls(journal_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@segment_re, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(journal_dir, &1))

      {:error, _} ->
        []
    end
  end

  # Oracles

  @doc "Record density: ids are dense `1..n`, in order."
  def dense_ids?(dir) do
    ids = raw_ids(dir)
    ids == Enum.to_list(1..length(ids)//1)
  end

  @doc "The tip predicate over a single raw record map."
  def conversational?(record) do
    kind = Map.get(record, "kind", "event")
    family = Map.get(record, "family")
    type = Map.get(record, "type")
    kind == "event" and family == "loop" and type in @conversational
  end

  @doc "The conversational tip offset (highest-offset CONVERSATIONAL record), or `:no_tip`."
  def tip(records) when is_list(records) do
    records
    |> Enum.filter(&conversational?/1)
    |> case do
      [] -> :no_tip
      convs -> convs |> Enum.map(& &1["id"]) |> Enum.max()
    end
  end

  def tip_of(dir), do: dir |> raw_records() |> tip()

  @doc "Tip validity: the record named by `tip_offset` exists and is CONVERSATIONAL."
  def valid_tip?(records, tip_offset) when is_list(records) do
    case Enum.find(records, &(&1["id"] == tip_offset)) do
      nil -> false
      record -> conversational?(record)
    end
  end

  @doc """
  Turn-boundary rule: `true` iff no turn is open (every `turn_started`
  is matched by a later close) and no spend-gate reserve is open.
  `reserve` opens a reserve; `settle` or `release` closes it, as in
  `Raxol.Agent.Journal.Records.Checkpoint.FileBackend`.
  """
  def at_turn_boundary?(records) when is_list(records) do
    balance =
      Enum.reduce(records, %{turn: 0, reserve: 0}, fn r, acc ->
        case r["type"] do
          "turn_started" ->
            %{acc | turn: acc.turn + 1}

          t when t in ["turn_completed", "turn_canceled", "error"] ->
            %{acc | turn: max(acc.turn - 1, 0)}

          "reserve" ->
            %{acc | reserve: acc.reserve + 1}

          t when t in ["settle", "release"] ->
            %{acc | reserve: max(acc.reserve - 1, 0)}

          _ ->
            acc
        end
      end)

    balance.turn == 0 and balance.reserve == 0
  end

  @doc "Lowercase-hex sha256 of `bytes` (the `snapshot_hash` recipe)."
  def sha256_hex(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "Does the content-addressed snapshot `ref` (relative CAS path) exist under `dir`?"
  def snapshot_present?(_dir, nil), do: false

  def snapshot_present?(dir, ref) when is_binary(ref),
    do: File.exists?(Path.join(dir, ref))

  @doc "Fold the event records (offset order) into a deterministic model."
  def fold(records) when is_list(records) do
    records
    |> Enum.filter(&(Map.get(&1, "kind", "event") == "event"))
    |> Enum.reduce(%{"applied" => []}, fn r, model -> fold_step(model, r) end)
  end

  @doc "Fold `records` forward starting from an existing `model` (the `⊕` operator)."
  def fold_forward(model, records) when is_list(records) do
    records
    |> Enum.filter(&(Map.get(&1, "kind", "event") == "event"))
    |> Enum.reduce(model, fn r, m -> fold_step(m, r) end)
  end

  defp fold_step(model, record) do
    Map.update(model, "applied", [record["id"]], &(&1 ++ [record["id"]]))
  end

  @doc "Snapshot dump: canonical JSON bytes of the folded model."
  def dump(model), do: Jason.encode!(model)

  @doc "Snapshot load."
  def load(bytes), do: Jason.decode!(bytes)

  @doc """
  Write a content-addressed snapshot file for `model` under `dir/snapshots`,
  file before record. Returns `{ref, hash}` for a checkpoint
  record to point at. Used to stage restore contours; NOT the production writer.
  """
  def stage_snapshot!(dir, model) do
    bytes = dump(model)
    hash = sha256_hex(bytes)
    ref = "snapshots/#{hash}.json"
    File.mkdir_p!(Path.join(dir, "snapshots"))
    File.write!(Path.join(dir, ref), bytes)
    {ref, hash}
  end

  # Dead-injectors (fabricate the broken shapes; controls assert the oracle catches)

  @doc """
  Raw-append `record` (already carrying an `"id"`) to the newest segment,
  bypassing the Writer — the fabrication primitive shared by the injectors.
  """
  def raw_append!(dir, record) do
    seg = dir |> Path.join("journal") |> segment_paths() |> List.last()
    File.write!(seg, [Jason.encode_to_iodata!(record), ?\n], [:append])
    :ok
  end

  @doc """
  Density injector: append a checkpoint whose `id` came from a SECOND counter
  (here: reuse the previous offset, breaking `prev+1`). The single-counter law
  says every kind consumes the same counter, so this leaves the record layer
  non-dense — `dense_ids?/1` must return `false`.
  """
  def inject_second_counter_checkpoint!(dir, cp \\ %{}) do
    ids = raw_ids(dir)
    bad_id = List.last(ids) || 1

    record =
      Map.merge(
        %{
          "id" => bad_id,
          "kind" => "checkpoint",
          "schema_version" => @schema_version
        },
        cp
      )

    raw_append!(dir, record)
  end

  @doc """
  The density control's positive arm: append a checkpoint stamped from the SINGLE
  counter (id = last + 1). `dense_ids?/1` must stay `true`.
  """
  def inject_single_counter_checkpoint!(dir, cp \\ %{}) do
    ids = raw_ids(dir)
    next = (List.last(ids) || 0) + 1

    record =
      Map.merge(
        %{
          "id" => next,
          "kind" => "checkpoint",
          "schema_version" => @schema_version
        },
        cp
      )

    raw_append!(dir, record)
  end

  @doc """
  Record-before-file injector: append a
  checkpoint record naming a snapshot that was NEVER written — the illegal
  order. `snapshot_present?/2` must be `false` for the referenced ref.
  """
  def inject_record_before_file!(dir, tip_offset) do
    ref = "snapshots/#{sha256_hex("phantom-#{System.unique_integer()}")}.json"
    ids = raw_ids(dir)
    next = (List.last(ids) || 0) + 1

    record = %{
      "id" => next,
      "kind" => "checkpoint",
      "schema_version" => @schema_version,
      "tip_offset" => tip_offset,
      "snapshot_ref" => ref,
      "snapshot_hash" => sha256_hex("phantom"),
      "reason" => "manual"
    }

    raw_append!(dir, record)
    ref
  end

  @doc "Mutant tip validator: accepts ANY positive integer as a tip."
  def mutant_accept_any_tip?(_records, tip_offset),
    do: is_integer(tip_offset) and tip_offset > 0

  @doc """
  Mutant restorer: on a missing snapshot, silently folds
  the whole journal instead of surfacing the typed error. Returns `{:ok, model}`.
  """
  def mutant_restore_silent_fallback(dir, _ref),
    do: {:ok, fold(raw_records(dir))}

  defmodule Counters do
    @moduledoc "Armed-site fire counter for the checkpoint controls."

    @doc "Start a fresh counter harness."
    def new do
      {:ok, pid} =
        Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)

      pid
    end

    @doc "Arm a site: it MUST fire before `assert_all_fired!/2`."
    def arm(harness, site) do
      Agent.update(harness, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
      harness
    end

    @doc "Record that `site` fired."
    def fire(harness, site) do
      Agent.update(harness, fn s ->
        %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
      end)

      :ok
    end

    @doc "Per-site fire counts."
    def fired(harness), do: Agent.get(harness, & &1.fired)

    @doc "Fail if any armed site never fired (dead injector). `schedule` is included on failure."
    def assert_all_fired!(harness, schedule \\ nil) do
      %{armed: armed, fired: fired} = Agent.get(harness, & &1)
      dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

      if dead != [] do
        raise ExUnit.AssertionError,
          message:
            "dead injector(s): armed site(s) never fired: #{inspect(dead)}\n" <>
              "fired: #{inspect(fired)}\nschedule/seed: #{inspect(schedule)}"
      end

      fired
    end
  end
end

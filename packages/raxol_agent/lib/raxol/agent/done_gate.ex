defmodule Raxol.Agent.DoneGate do
  @moduledoc """
  Evidence-gated done: a pure decision over a turn journal.

  An agent may not declare a turn done on its own say-so. A
  `turn_completed{final: true}` must cite journaled evidence (tool results,
  verification output) that postdates the turn's last mutating action.

  Evidence is named by `refs`, journal offsets on the proposed done. Refs are
  checked in order and the first violation wins. Each ref must:

    1. exist, else `{:error, {:missing_ref, offset}}`;
    2. be evidence-class (a tool result, never a `:message` self-report or a
       `:state_change`), else `{:error, {:not_evidence, offset}}`;
    3. belong to the claiming turn, else `{:error, {:foreign_turn, offset}}`,
       even when it postdates this turn's last mutation;
    4. postdate the turn's last mutation, else
       `{:error, {:stale_evidence, offset}}`;
    5. not be the last mutation's own result, else
       `{:error, {:mutation_echo, offset}}`.

  A done with no refs is `{:error, :evidence_required}`. A done whose claiming
  `turn_id` is nil is `{:error, :unturned_done}` before any ref is checked:
  checks 3 and 4 are keyed on the turn. When every ref passes, the gate
  returns the durable `turn_completed{final: true, refs: [...]}` to journal.
  A rejected claim leaves the turn open.

  ## Mutations

  Every completed `:tool_use` is a mutation. Producers stamp no effect
  metadata, and effect classification must be structural, never
  self-reported, so:

    * an absent `effect_class` counts as a mutation;
    * a stamped `mutating: false` (or any `destructiveHint`-style claim) never
      removes a call from the mutation set, or a lying producer could launder
      stale evidence past a real mutation;
    * only a structural classification (`classified_effect_free?/1`, not yet
      implemented) may exempt a call.

  A result is paired with its call by tool `name` and nearest preceding
  order, the only link the v0 producer shape carries. On today's journals
  every tool call gates and no tool result can pass check 5, so the gate is
  fully fail-closed until a structurally classified verification class
  exists.

  Evidence class is checked, not content: a test run that reported failures
  still counts as a verification tool that ran.

  ## Wiring

  `Raxol.Agent.StreamPump.pump/3` consults `gate/3` observe-only: it derives
  candidate refs (`evidence_refs/2`), calls the gate and emits
  `[:raxol, :agent, :done_gate, :ungated_done]` (no evidence cited) or
  `[:raxol, :agent, :done_gate, :rejected_evidence]` (metadata carries
  `reason`), but the turn still closes. Blocking needs structural mutation
  classes and a way for an agent to cite its own evidence; whether a
  zero-tool turn may ever be done is undecided.

  `gate/3` is a behaviour callback so tests can drive deliberately broken
  implementations through the same shape.
  """

  alias Raxol.Agent.Contract.Event

  @typedoc "A journal offset (`Event.id`), the currency `refs` are stated in."
  @type offset :: non_neg_integer()

  @typedoc """
  A turn's journal: contract events in offset order. Each carries `id` (the
  offset), `turn_id`, `type`, and `payload` (see `Raxol.Agent.Contract.Event`).
  """
  @type journal :: [Event.t() | map()]

  @typedoc """
  The gate verdict. Accept hands back the done event to journal; every reject is
  a distinct typed error naming the offending ref where one applies.
  """
  @type verdict ::
          {:ok, Event.t()}
          | {:error, :evidence_required}
          | {:error, :unturned_done}
          | {:error, {:missing_ref, offset()}}
          | {:error, {:not_evidence, offset()}}
          | {:error, {:foreign_turn, offset()}}
          | {:error, {:stale_evidence, offset()}}
          | {:error, {:mutation_echo, offset()}}

  @doc """
  Gate a proposed done for `turn_id` against `journal`, citing evidence `refs`.

  See the moduledoc for the acceptance contract. Returns `{:ok, done_event}`
  (a `turn_completed{final: true, refs: refs}` to be journaled) or a typed
  rejection; the turn does not transition to done on a rejection.
  """
  @callback gate(journal(), turn_id :: term(), refs :: [offset()]) :: verdict()

  @doc """
  Gate a proposed done for `turn_id` against `journal`, citing evidence `refs`.

  A nil claiming turn is `{:error, :unturned_done}` (structural — see the
  moduledoc; checked first, before evidence). A done with no refs is
  `{:error, :evidence_required}`. Otherwise refs are walked in caller order and
  the first violation wins (existence -> class -> same-turn -> ordering). On
  acceptance, hands back the durable `turn_completed{final: true, refs: refs}`
  event to journal.
  """
  @spec gate(journal(), term(), [offset()]) :: verdict()
  # A nil claiming turn cannot be gated: same-turn ownership and the last-
  # mutation window both key on turn_id, and `nil == nil` would let any nil-turn
  # ref pass. Reject structurally, ahead of the evidence checks, for ANY refs.
  def gate(_journal, nil, _refs), do: {:error, :unturned_done}

  def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

  def gate(journal, turn_id, refs) do
    # One walk builds the offset index; each ref is then an O(1) lookup
    # instead of a fresh whole-journal Enum.find per ref.
    by_offset = Map.new(journal, &{event_id(&1), &1})
    last_mut = last_mutation(journal, turn_id)

    Enum.reduce_while(refs, {:ok, refs}, fn ref, acc ->
      case classify_ref(journal, by_offset, turn_id, last_mut, ref) do
        :ok -> {:cont, acc}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _refs} -> {:ok, done_event(journal, turn_id, refs)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Candidate evidence refs for `turn_id`: journal offsets of the turn's own
  `:tool_result` events that postdate its last mutating action.

  This mirrors the gate's evidence-class + ordering window so a producer can
  cite the refs it would offer without re-deriving the notion of evidence.
  It does NOT pre-apply the mutation-echo check (check 5): those candidates are
  handed to `gate/3`, which remains the sole authority on acceptance. On a
  journal from today's v0 producer (no structural effect classification) the
  gate is fully fail-closed, so most candidates resolve to `:mutation_echo`;
  an empty list resolves to `:evidence_required`.
  """
  @spec evidence_refs(journal(), term()) :: [offset()]
  def evidence_refs(journal, turn_id) do
    last_mut = last_mutation(journal, turn_id)

    journal
    |> Enum.filter(fn ev ->
      event_turn_id(ev) == turn_id and evidence_class?(ev) and
        (last_mut == nil or event_id(ev) > last_mut)
    end)
    |> Enum.map(&event_id/1)
  end

  # Order: existence -> class -> same-turn -> ordering -> mutation-echo.
  # First violation wins; refs are walked in caller order.

  defp classify_ref(journal, by_offset, turn_id, last_mut, ref) do
    case Map.get(by_offset, ref) do
      nil ->
        {:error, {:missing_ref, ref}}

      ev ->
        cond do
          not evidence_class?(ev) ->
            {:error, {:not_evidence, ref}}

          event_turn_id(ev) != turn_id ->
            {:error, {:foreign_turn, ref}}

          last_mut != nil and event_id(ev) <= last_mut ->
            {:error, {:stale_evidence, ref}}

          mutation_echo?(journal, turn_id, ev, last_mut) ->
            {:error, {:mutation_echo, ref}}

          true ->
            :ok
        end
    end
  end

  # Offset of the turn's last mutating action, or nil if the turn mutated nothing.
  defp last_mutation(journal, turn_id) do
    journal
    |> Enum.filter(&(event_turn_id(&1) == turn_id and mutating?(&1)))
    |> Enum.map(&event_id/1)
    |> case do
      [] -> nil
      ids -> Enum.max(ids)
    end
  end

  # Evidence-class predicate: a tool result / verification output.
  defp evidence_class?(ev) do
    event_type(ev) == :item_completed and
      payload_field(ev, :item_type) == :tool_result
  end

  # Mutation predicate — FAIL-SAFE, derived at decision time from the event's
  # intrinsic type (admission gates fold truth
  # synchronously; a producer stamp is display/audit metadata, the fold is the
  # security boundary). Every completed `:tool_use` is a mutation: the real
  # producer (`StreamPump.pump/3`) stamps no effect metadata, and the frozen
  # effect taxonomy contains only effect-BEARING classes, so neither an
  # absent `effect_class` nor any self-reported flag (`mutating: false`, a
  # `destructiveHint`-style claim) may ever REMOVE a tool call from the
  # mutation set — a lying producer must not be able to widen the
  # valid-evidence window and launder stale evidence past a real mutation.
  #
  # (`:state_change` is deliberately NOT in the mutating set: it is an internal
  # transition, neither evidence nor mutation in the v0 loop vocabulary, and
  # the frozen Oracle/fold treats it the same way.)
  defp mutating?(ev) do
    event_type(ev) == :item_completed and
      payload_field(ev, :item_type) == :tool_use and
      not classified_effect_free?(ev)
  end

  # The one refinement seam: a tool call leaves the mutation set ONLY via a
  # structural, compiled-in-our-own-tree classification proving it effect-free
  # (see the moduledoc). No such class exists in
  # the frozen taxonomy today, so this is constantly false: unclassified and
  # unknown both resolve toward "is a mutation".
  defp classified_effect_free?(_ev), do: false

  # Check 5 — is this `:tool_result` the last mutation's own echo?
  #
  # A result is paired to its producing call by tool NAME + nearest-preceding
  # order within the claiming turn: the v0 producer emits each result
  # sequentially after its call and stamps `name` on both sides (it stamps no
  # `call_id` on results, so name+order is the only pairing signal in the
  # frozen shape). If the producing call IS the turn's last mutation, the ref
  # is that mutation's byproduct — it postdates the mutation trivially and
  # verifies nothing. An unpaired result (no named preceding call in the turn)
  # is not an echo.
  defp mutation_echo?(_journal, _turn_id, _ev, nil), do: false

  defp mutation_echo?(journal, turn_id, ev, last_mut) do
    name = tool_name(ev)
    offset = event_id(ev)

    name != nil and
      journal
      |> Enum.filter(fn cand ->
        event_turn_id(cand) == turn_id and mutating?(cand) and
          event_id(cand) < offset and tool_name(cand) == name
      end)
      |> Enum.map(&event_id/1)
      |> case do
        [] -> false
        ids -> Enum.max(ids) == last_mut
      end
  end

  # Tool names are free-form strings on the wire — read raw (never atomized)
  # and normalize atoms from synthetic fixtures to their string form.
  defp tool_name(ev) do
    case get_either(ev, :payload) do
      %{} = payload ->
        case get_either(payload, :name) do
          name when is_binary(name) -> name
          name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  #
  # A journal that reaches the gate straight from `StreamPump.pump`/`EmitBridge`
  # is atom-keyed `%Event{}` structs. One replayed from disk via
  # `Raxol.Agent.Journal.FileStore.Reader` is `Jason.decode`d into string-keyed
  # maps — both the KEYS and the stringifiable enum VALUES (`type`, `item_type`,
  # `effect_class`) arrive as strings. No layer rehydrates those back to atoms
  # before the gate, so these accessors read either shape and normalize enum
  # values with `atomize/1`, keeping the gate's verdict identical on the live
  # and replayed forms of the same journal.

  defp event_id(ev), do: get_either(ev, :id)
  defp event_turn_id(ev), do: get_either(ev, :turn_id)
  defp event_session_id(ev), do: get_either(ev, :session_id)
  defp event_type(ev), do: atomize(get_either(ev, :type))

  defp payload_field(ev, key) do
    case get_either(ev, :payload) do
      %{} = payload -> atomize(get_either(payload, key))
      _ -> nil
    end
  end

  # Prefer the atom key; fall back to its string form for replayed journals.
  defp get_either(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp get_either(_map, _key), do: nil

  # Normalize a possibly-stringified enum value to its atom form so the type
  # comparisons hold across live and replayed journals. `to_existing_atom`
  # never fabricates atoms (no memory-leak risk on decoded input): an unknown
  # string simply stays a string and fails the atom comparisons — the safe
  # default. Booleans/numbers pass through unchanged.
  defp atomize(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp atomize(value), do: value

  # The durable done event handed back to the journal. On append the Writer
  # stamps only `id` (= the real journal offset), overwriting the `next_id`
  # hint carried here; it does NOT re-stamp `session_id`, `ts`, or the envelope
  # (`Writer.stamp/3` puts `"id"`/`"schema_version"` and nothing else), so those
  # must be well-formed at hand-back.
  #
  # `session_id` is derived from the CLAIMING TURN's own events (they carry the
  # session) rather than `List.first/1` of the journal: the head may belong to
  # an interleaved foreign turn or a GC-dropped prefix, and on a string-keyed
  # replay it would not even carry an atom `:session_id` key.
  #
  # `ts` is a monotonic, offset-derived placeholder — the gate is a pure
  # decision function and reads no wall clock; a producer seam may set a real
  # timestamp when the accepted done is actually emitted.
  defp done_event(journal, turn_id, refs) do
    next_id =
      journal
      |> Enum.map(&event_id/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 0
        ids -> Enum.max(ids) + 1
      end

    session_id =
      journal
      |> Enum.find(&(event_turn_id(&1) == turn_id))
      |> then(&(&1 && event_session_id(&1)))

    %Event{
      v: 0,
      id: next_id,
      session_id: session_id,
      turn_id: turn_id,
      ts: next_id,
      family: :loop,
      type: :turn_completed,
      tier: :durable,
      payload: %{final: true, refs: refs, usage: %{}}
    }
  end
end

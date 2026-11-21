defmodule Raxol.AgentClientProtocol.Telemetry do
  @moduledoc """
  Registry of every `:telemetry` event this package emits, with its class:

    * `:invariant` -- can only fire if this library is wrong. The test suite's
      `InvariantSentinel` fails any test in which one fires.
    * `:peer` -- caused by a misbehaving remote peer (malformed frame, late id).
    * `:operational` -- normal life (delivery decisions, shedding, idle reaps).

  If a peer, the network, the clock or a library user can cause an event, it is
  not an invariant. The test suite fails if `lib/` emits an event missing from
  `events/0`, or if `events/0` lists one nothing emits.

  `:telemetry` is optional: `execute/2,3` are no-ops when it is not loaded.
  """

  @compile {:no_warn_undefined, :telemetry}

  @typedoc "Telemetry event name, as passed to `:telemetry.execute/3`."
  @type event :: [atom(), ...]

  @type class :: :invariant | :peer | :operational

  # Sorted by event name.
  @events %{
    [:raxol, :acp, :attach, :denied] => :operational,
    [:raxol, :acp, :attach, :granted] => :operational,
    # Fires for every session/update delivery decision; the decision is metadata.
    [:raxol, :acp, :delivery] => :operational,
    # Discharging one reply_ref twice: the Connection's own bookkeeping error.
    [:raxol, :acp, :dup_reply] => :invariant,
    [:raxol, :acp, :duplicate_inflight_id] => :peer,
    # A caller streamed an empty content chunk (API misuse, rejected).
    [:raxol, :acp, :empty_chunk_rejected] => :operational,
    # A user-supplied handler crashed; containing it is our job.
    [:raxol, :acp, :handler_crash] => :operational,
    [:raxol, :acp, :inbound_shed] => :operational,
    [:raxol, :acp, :invalid_request_frame] => :peer,
    # Reachable through caller-built attach topologies (two surfaces racing).
    [:raxol, :acp, :journal, :non_holder_turn_completed] => :operational,
    [:raxol, :acp, :late_response] => :peer,
    [:raxol, :acp, :malformed_response] => :peer,
    [:raxol, :acp, :notification_shed] => :operational,
    # An out-of-turn update for a session outside the per-connection tracking cap
    # (too many sessions, or an id over 256 bytes).
    [:raxol, :acp, :oot_untracked] => :peer,
    [:raxol, :acp, :parse_error] => :peer,
    [:raxol, :acp, :session_idle_reaped] => :operational,
    [:raxol, :acp, :unknown_notification] => :peer,
    # A non-empty prompt's turn completed with zero session/updates. In our own
    # suite the turn runner is us, so this means the update stream was lost.
    # Tests that drive such a turn on purpose tag `expect_invariant:`.
    [:raxol, :acp, :zero_updates_turn] => :invariant
  }

  @invariant_events @events
                    |> Enum.filter(fn {_event, class} -> class == :invariant end)
                    |> Enum.map(fn {event, _class} -> event end)
                    |> Enum.sort()

  @doc "Every event this package emits, mapped to its class."
  @spec events() :: %{event() => class()}
  def events, do: @events

  @doc "The sorted `:invariant` subset of `events/0`."
  @spec invariant_events() :: [event()]
  def invariant_events, do: @invariant_events

  @doc "The class of `event`, or `nil` when it is not registered."
  @spec classify(event()) :: class() | nil
  def classify(event) when is_list(event), do: Map.get(@events, event)

  @doc "Emits `event` with `%{count: 1}` measurements and `metadata`."
  @spec execute(event(), map()) :: :ok
  def execute(event, metadata), do: execute(event, %{count: 1}, metadata)

  @doc "Emits `event` via `:telemetry` when it is loaded; otherwise does nothing."
  @spec execute(event(), map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry), do: :telemetry.execute(event, measurements, metadata)
    :ok
  end
end

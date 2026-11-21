defmodule Raxol.AgentClientProtocol.Delivery do
  @moduledoc """
  Delivery vocabulary shared by `Connection` (stamping + direct turn
  delivery) and `Client` (turn consumption).

  The ordering key is a receiver-assigned contiguous per-turn ordinal,
  stamped at the single sequential demux point before any per-session
  fan-out. It is never read from the peer's `_meta`: arrival order is not
  stable across a reattach onto a new connection, and a peer that supplied
  the key could manufacture a gap to force the degraded path. Every
  drop/gap decision emits telemetry rather than dropping silently, and the
  per-turn namespace that scopes the ordinals is receiver-minted too, so a
  peer reusing a turn id cannot alias a stale turn's straggler forward.

  ## Message shapes (the direct turn-delivery channel)

  For a turn opened by a `session/prompt` submitted via
  `Connection.async_request/6` (`reply_to = {:owner, owner, tag}`), the
  Connection sends `owner` three message shapes directly, ALL from the
  Connection process itself — the same single-sender operation
  `Connection.Link.deliver/2` uses for the terminal result — so BEAM's
  per-sender-per-receiver FIFO guarantees the owner's mailbox order equals
  demux order equals wire order:

    * `{:acp_turn_update, tag, ordinal, notification}` — one per
      `session/update` notification belonging to the turn's session,
      stamped with a contiguous per-turn ordinal starting at 0.
    * `{:acp_turn_end, tag, count}` — sent exactly once, immediately before
      the terminal `{:acp_result, tag, outcome}`; `count` is the number of
      `:acp_turn_update` messages the owner should have received (ordinals
      `0..count-1`).
    * `{:acp_result, tag, outcome}` — the terminal delivery
      (`Connection.async_request/6`'s outcome).

  Because the Connection is the single sender of all three shapes, a
  consumer needs no settle timer and no reorder buffer on this path:
  `delivered < count` observed at the terminal result is a definite,
  synchronous signal of dropped updates, never a race.

  ## The stamp (broadcast path)

  `t:t/0` is the per-notification ordering key threaded onto
  `Connection.Ctx.delivery_stamp` for every `session/update` dispatch
  (`nil` for anything else) — for the multi-sender broadcast path
  (`subscribe/3`, custom `session_update/2` overrides) that still fans out
  through per-notification dispatch tasks and therefore needs an explicit
  key to reconstruct order. `turn` is the receiver-minted turn token (`nil`
  when the update is out-of-turn — no open prompt turn for the session on
  this connection); `ordinal` is the contiguous per-(session, namespace)
  stamp assigned at the demux point (out-of-turn updates for sessions beyond
  the connection's tracking cap of 10,000 are all stamped 0); `rx_seq` is the connection-wide
  monotone frame stamp (used by the separate cancel/prompt wire-order
  latch).
  """

  @typedoc "Per-notification ordering key, receiver-assigned at the demux point."
  @type t :: %__MODULE__{
          turn: reference() | nil,
          ordinal: non_neg_integer(),
          rx_seq: non_neg_integer()
        }

  @enforce_keys [:ordinal, :rx_seq]
  defstruct turn: nil, ordinal: 0, rx_seq: 0

  @doc "Build a Stamp."
  @spec new(reference() | nil, non_neg_integer(), non_neg_integer()) :: t()
  def new(turn, ordinal, rx_seq) when is_integer(ordinal) and is_integer(rx_seq) do
    %__MODULE__{turn: turn, ordinal: ordinal, rx_seq: rx_seq}
  end

  @doc """
  Emits `[:raxol, :acp, :delivery]`. `metadata` carries `:decision`
  (`:emit | :buffer | :gap | :fail`) plus any of `:session`, `:turn`,
  `:buffered`, `:ordinal`.
  """
  @spec emit(map()) :: :ok
  def emit(metadata) when is_map(metadata) do
    Raxol.AgentClientProtocol.Telemetry.execute([:raxol, :acp, :delivery], metadata)
  end
end

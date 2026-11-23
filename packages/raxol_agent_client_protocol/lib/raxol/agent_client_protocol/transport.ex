defmodule Raxol.AgentClientProtocol.Transport do
  @moduledoc """
  Behaviour for pluggable ACP message carriers.

  A transport moves *decoded* JSON-RPC frames (maps) between a local owner
  process and a peer. `Raxol.AgentClientProtocol.Connection` only calls
  `send_message/2` and `close/1`. Concrete transports:

    * `Raxol.AgentClientProtocol.Transport.Paired` -- an in-process pair of
      handles; maps pass straight through, no encode/decode.
    * `Raxol.AgentClientProtocol.Transport.Stdio` -- newline-delimited JSON
      over stdin/stdout.

  ## Ownership

  Every handle has an owner process that receives its inbound traffic.
  Constructors may leave it `nil` so a supervisor can create transports before
  the `Connection` exists; the concrete transport's `set_owner/2` adopts it.

  ## Inbound messages

    * `{:acp_transport, transport_ref, {:message, message}}` -- one decoded
      JSON-RPC frame.
    * `{:acp_transport, transport_ref, {:closed, reason}}` -- no further
      messages (`:peer_closed`, `:local_close`, `{:error, term}`, ...).
    * `{:acp_transport, transport_ref, {:decode_error, reason, raw}}` -- byte
      transports only (`Stdio`, never `Paired`): one unit of wire input failed
      to decode. It occupies the failed frame's stream position (T-ORD).

  `transport_ref` is opaque; compare it with `==/2`, never match into it.

  ## Delivery guarantees

  Mandated, not negotiated: there is no capability flag. A carrier whose medium
  does not preserve order must restore it internally before emitting
  `{:message, _}`; ordering is never a field on the ACP wire.

    * **T-ORD** -- per direction, frames (and `:decode_error`s) reach the owner
      in exactly the order the peer's single-writer send path accepted them.
      A receiver that stamps an ordinal where it processes inbound messages
      gets a faithful ordering key with no reorder buffer.
    * **T-REL** -- a frame accepted by `send_message/2` is eventually delivered
      or the stream ends with `{:closed, reason}`; never dropped while later
      frames still arrive. `{:ok, state}` means accepted, not processed.
    * **T-DUP** -- each accepted frame is delivered at most once (exactly once
      unless a `{:closed, _}` precedes it). Both ends may send concurrently.
    * **T-TERM** -- `{:closed, reason}` is delivered at most once and nothing
      follows it.

  Loss or reorder is permitted only after `close/1` on either end or a delivered
  `{:closed, _}`, where `{:error, :closed}` or no delivery is expected.
  """

  @typedoc "The process that receives a transport's inbound `{:acp_transport, ...}` messages."
  @type owner :: pid()

  @typedoc "Opaque identifier for a transport handle, included in every inbound delivery."
  @type transport_ref :: term()

  @typedoc "Transport-implementation-defined handle/state threaded through the callbacks."
  @type state :: term()

  @doc """
  Send one decoded JSON-RPC frame (a map) to the peer.

  Returns `{:ok, state}` (the possibly-updated transport state) on
  successful hand-off, or `{:error, reason}` if the transport cannot
  accept the message (e.g. `:closed`).
  """
  @callback send_message(state(), map()) :: {:ok, state()} | {:error, term()}

  @doc """
  Close the transport.

  Idempotent: closing an already-closed transport returns `:ok`. Must
  cause the peer's owner to eventually receive
  `{:acp_transport, transport_ref, {:closed, reason}}`.
  """
  @callback close(state()) :: :ok
end

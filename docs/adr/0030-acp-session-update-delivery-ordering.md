# ADR-0030: ACP `session/update` delivery ordering

## Status

Accepted. Implemented in `Raxol.AgentClientProtocol.Delivery` and `Connection`.

## Context

The ACP client delivers `session/update` notifications to an `on_update` handler while a turn
streams. Updates must arrive in order, none may be dropped silently, and delivery must be
incremental (O(1) memory), not buffered until the turn ends. Earlier attempts ordered updates
by a sequence number that the peer supplied in `_meta`. A buggy or hostile peer could reuse,
withhold or freeze that number and break both guarantees.

## Decision

Any implementation must satisfy five clauses.

1. **Receiver-assigned, contiguous ordering key.** A per-turn ordinal stamped at the single
   sequential demux point, before any per-session fan-out. It is never read from the peer's
   `_meta`. Because ordinals are contiguous, a peer cannot create a gap.
2. **Bounded, observable reordering.** Every emit, buffer, gap or fail decision emits
   `[:raxol, :acp, :delivery]` telemetry, so nothing is dropped silently. A reorder buffer has a
   watermark, and reaching it fails the turn instead of growing or trimming the buffer.
3. **Overflow-bounded, never timer-bounded.** No guarantee depends on a wall-clock settle window.
   A gap resolves only when the missing ordinal arrives, or fails the turn on disconnect or
   watermark. A gap marker is allowed only for update types declared coalescible.
4. **Streaming preserved.** `on_update` fires per update during the turn, in O(1) memory.
5. **Receiver-assigned turn namespace.** The namespace that scopes ordinals is a receiver-minted
   turn token, so a peer that reuses a turn id cannot alias a stale straggler into the next turn.

As built:

- Direct turn path: the `Connection` process is the only sender of `{:acp_turn_update, tag,
  ordinal, n}`, `{:acp_turn_end, tag, count}` and `{:acp_result, tag, outcome}`. BEAM FIFO
  between one sender and one receiver guarantees wire order, so the consumer needs no reorder
  buffer and no timer. Receiving fewer than `count` updates before the result means updates were
  dropped.
- Broadcast path (`subscribe/3`, custom `session_update/2`): each dispatch carries a `Delivery`
  stamp (`turn`, `ordinal`, `rx_seq`). The bounded reorder engine for this path is not built.
- Reattach/replay re-delivers ordinals that were already stamped and never renumbers them, so a
  replay is idempotent by ordinal.

## Consequences

- A hostile peer cannot steer delivery order or force a silent drop.
- `test/connection_delivery_test.exs` pins the hostile-peer cases and checks by grep that no
  settle timer exists in `client.ex` or `delivery.ex`.

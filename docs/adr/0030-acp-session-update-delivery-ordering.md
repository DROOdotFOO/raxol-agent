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

1. The receiver assigns the ordering key: a contiguous ordinal for each turn, stamped at the
   single sequential demux point before any per-session fan-out. It is never read from the
   peer's `_meta`. Because ordinals are contiguous, a peer cannot create a gap.
2. The per-turn namespace is receiver-minted too (a turn token), so a peer that reuses a turn
   id cannot alias a stale turn's straggler into the next turn.
3. Direct turn path: the `Connection` process is the only sender of `{:acp_turn_update, tag,
   ordinal, n}`, `{:acp_turn_end, tag, count}` and `{:acp_result, tag, outcome}`. BEAM FIFO
   between one sender and one receiver then guarantees wire order, so the consumer needs no
   reorder buffer and no settle timer. If the consumer has received fewer than `count` updates
   when the result arrives, updates were dropped, and it knows this at once.
4. Broadcast path (`subscribe/3`, custom `session_update/2`): each dispatch carries a
   `Delivery` stamp (`turn`, `ordinal`, `rx_seq`) so the consumer can rebuild the order.
5. No guarantee depends on a wall-clock timer. Every gap or failure decision emits
   `[:raxol, :acp, :delivery]` telemetry instead of dropping silently.
6. Reattach/replay re-delivers ordinals that were already stamped and never renumbers them, so a
   replay is idempotent by ordinal.

## Consequences

- A hostile peer cannot steer delivery order or force a silent drop.
- Lossless resolution of a gap fails the turn, never skips past the hole.
- `test/connection_delivery_test.exs` pins the hostile-peer cases and checks by grep that no
  settle timer exists in `client.ex` or `delivery.ex`.

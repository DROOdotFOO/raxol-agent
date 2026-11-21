# ADR-0039: Required callback set and partial sources

## Status

Accepted, 2026-09-14. Amends [ADR-0033](0033-web3-data-surface.md) decision 2.

## Context

ADR-0033 required six backend callbacks. Several real sources cannot answer four of them. A raw
JSON-RPC node cannot list transactions by account. Aztec's public surface has no account
resource. SQD Portal answers queries over block ranges, so it reports no current balance and
cannot look up a Solana transaction by signature. If those callbacks stay required, a partial
source either has to lie or cannot be written.

## Decision

1. Only two callbacks are required: `chain_info/1` and `block_height/1`, which describe the chain
   itself. `get_transaction/2`, `account_info/2`, `list_transactions/3` and `token_balances/3`
   become optional, so 12 of the 14 callbacks are optional. `Backend.supports?/2` checks
   `capabilities/1` and `function_exported?/3`.
2. There is one contract, not a second behaviour for partial sources. `Raxol.Web3.Router` already
   selects candidates per callback.
3. A callback a source cannot answer is absent. The router returns
   `{:error, {:unsupported, callback}}`, and `Router.coverage/2` omits the entry. Nothing returns
   an empty page that a gate could read as zero, and no new error variant is added.
4. `Raxol.Web3.Backend.JSONRPC` is the first partial source and the routable fallback for chain
   4663. It answers `eth_call` and `eth_getLogs`, which a challenge-gated explorer cannot.
5. A handle can name its source through the optional `backend/1` callback, so `coverage/2` and the
   failover log name the upstream (for example TronGrid as opposed to SQD), not just the module.
6. `token_balances/3` takes `list_opts`, so a cursor a backend returns can be handed back.

## Consequences

- `Router.coverage/2` is the only place that shows what a chain's surface really answers, with
  live breaker state.
- Each new source declares what it answers instead of stubbing what it cannot.

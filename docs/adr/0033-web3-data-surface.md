# ADR-0033: Indexer-agnostic web3 read layer (`raxol_web3`)

## Status

Accepted. Implemented in `packages/raxol_web3` (ADR-0038, ADR-0039, ADR-0040). Decision 3's
required callback set is amended by [ADR-0039](0039-required-callback-set-partial-sources.md).

## Context

`raxol_payments` and `raxol_earn` settle across EVM chains and Tron. No vendor indexes all the
chains we need: Blockscout is EVM-only and declined Tron, Solana, Canton and Aztec. Blockscout
relicensed its MCP server and indexer in 2026, so forking them is ruled out. Calling its public
REST API carries no licence obligation.

## Decision

1. Build the read layer ourselves as `raxol_web3`. It depends on `raxol_core`, `raxol_mcp` and
   `mint`. `raxol_payments` takes it as an optional dependency, and `raxol_agent` exposes it
   through an agent action.
2. `Raxol.Web3.Backend` is the source contract: a `{module, state}` handle, `capabilities/1`, and
   optional callbacks guarded by `function_exported?/3`. Three shapes are load-bearing:
   - `block_height/1` returns `{height, finalized_height, unit}`, where unit is `:block`,
     `:slot`, `:offset` or `:round`.
   - Accounts are opaque tagged references, not addresses (Canton has party IDs).
   - Pagination uses opaque cursors in both directions, never offsets.
3. Chains are identified by CAIP-2 strings. `Raxol.Web3.Router` resolves a chain to an ordered
   fallback list of backends, with health tracked by `Raxol.MCP.CircuitBreaker`.
4. The served surface is read-only. Every MCP tool is marked `readOnlyHint: true` and
   `sensitive: true`, so the server must have an authorizer. `raw_request/2` is limited to a
   compile-time allowlist of read methods in each backend. Writes stay behind the spend-gated
   actions in `raxol_payments`.
5. Outbound requests are hardened (enforced by ADR-0038's guarded client): `https` only; every
   resolved address is checked against loopback, link-local, private and mapped ranges; the
   connection dials the vetted address; redirects are refused; and timeout, size and
   concurrency are bounded. Credentials a caller supplies are held only for the request and
   never logged, cached or stored. Upstream tool descriptions are treated as untrusted text.
6. Free-tier limits go through `Raxol.Core.TokenBucket` keyed by upstream origin, and responses
   are cached in `Raxol.Web3.Cache` (ETS).

## Consequences

- Backends ship: JSON-RPC (EVM), Blockscout, SQD Portal, Solana, Tron, Aztec, Canton, and a
  stub. Reference implementations live in `lib/`, and no mocking library is used.
- Rate-limit buckets and the cache are local to each node, so a fleet of N nodes spends N times
  the upstream budget.
- Free upstream sources can change terms, so the fallback chains are load-bearing.

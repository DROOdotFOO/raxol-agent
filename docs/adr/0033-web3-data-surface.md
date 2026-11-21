# ADR-0033: Indexer-agnostic web3 read layer (`raxol_web3`)

## Status

Accepted. Implemented in `packages/raxol_web3` (ADR-0038, ADR-0039, ADR-0040). Decision 3's
required callback set is amended by [ADR-0039](0039-required-callback-set-partial-sources.md).

## Context

`raxol_payments` and `raxol_earn` settle across EVM chains and Tron. No vendor indexes all the
chains we need: Blockscout is EVM-only and declined Tron, Solana, Canton and Aztec. Blockscout
relicensed its MCP server and indexer in 2026, so forking them is ruled out. Calling its public
REST API carries no licence obligation.

Three gaps in the code at the time:

1. There was no block-explorer client. Every on-chain read was a hand-rolled `eth_call`,
   `balanceOf` or `eth_getLogs`, so historical transfers, token lists and verified ABIs had
   nowhere to come from.
2. RPC URLs were resolved five different ways (`RPC_<NAME>`, `DERIVE_RPC_<chain_id>`,
   `ORDER_RPC_<chain_id>`, `XOCHI_ORDER_RPC_<chain_id>`, `GATE_RPC_<chain_id>`), and chain 4663
   had no public RPC default in library code; its only URL lived in a shell script.
3. Two read paths could not share code: `Raxol.Payments.ChainReader` hand-rolled a JSON-RPC
   adapter because using `raxol_earn`'s `Onchain.RPC` would be a dependency cycle. The read
   layer sat at the wrong level of the graph.

## Decision

1. `Raxol.MCP.Aggregator`, which would re-serve an upstream MCP server's own tools, is not built.
   Nothing in `raxol_web3` re-serves upstream tools.
2. Build the read layer ourselves as `raxol_web3`. It depends on `raxol_core`, `raxol_mcp` and
   `mint`. `raxol_payments` takes it as an optional dependency, and `raxol_agent` exposes it
   through an agent action. The planned moves of `ChainReader`, `Poll` and `Pxe.Client` out of
   `raxol_payments` have not happened.
3. `Raxol.Web3.Backend` is the source contract: a `{module, state}` handle, `capabilities/1`, and
   optional callbacks guarded by `function_exported?/3`. Its required set is amended by ADR-0039.
   Three shapes are load-bearing:
   - `block_height/1` returns `{height, finalized_height, unit}`, where unit is `:block`,
     `:slot`, `:offset` or `:round`.
   - Accounts are opaque tagged references, not addresses (Canton has party IDs).
   - Pagination uses opaque cursors in both directions, never offsets.

   Chains are identified by CAIP-2 strings. `Raxol.Web3.Router` resolves a chain to an ordered
   fallback list of backends, with health tracked by `Raxol.MCP.CircuitBreaker`. Reference
   implementations ship in `lib/`.
4. The served surface is read-only. MCP `tool_def` maps are written directly. The existing
   `Raxol.MCP.AgentBridge` is not used: it had no caller, it drops the `sensitive` flag instead
   of emitting an annotation, and it formats results with `inspect/2` rather than JSON. Every MCP
   tool is marked `readOnlyHint: true` and
   `sensitive: true`, so the server must have an authorizer. `raw_request/2` is limited to a
   compile-time allowlist of read methods in each backend. Writes stay behind the spend-gated
   actions in `raxol_payments`.
5. Chain coverage comes from free sources, each with a fallback: Blockscout REST for EVM, SQD Portal
   and TronGrid/TronScan for Tron, SQD Portal and public RPC for Solana, aztecscan for Aztec, and
   Splice Scan/ccscan for Canton.
6. Reuse the existing primitives: `Raxol.MCP.Client`, `Raxol.MCP.CircuitBreaker`, and
   `Raxol.Core.TokenBucket` keyed by upstream origin. The response cache is rebuilt as
   `Raxol.Web3.Cache` (ETS). One pattern is adopted by analogy from
   `Raxol.Agent.Backend.Resolver`, which refuses to auto-select a metered provider: a free
   endpoint may be chosen automatically, a metered one only when explicitly configured.
7. Security constraints on every outbound request (enforced by ADR-0038's guarded client):
   1. `https` only.
   2. Every resolved address, IP literals included, is checked against loopback, link-local,
      private, unique-local, IPv4-mapped and `0.0.0.0/8` ranges.
   3. The checked address is the address dialled.
   4. Redirects are refused.
   5. Timeout, size and concurrency are bounded per target.
   6. Requests identify honestly with a fixed `User-Agent` (format in ADR-0038 decision 9).

   Credentials a caller supplies are held only for the request and never logged, cached or
   stored. Upstream errors are rebuilt from the status plus a redacted reason. Upstream tool
   descriptions are treated as untrusted text.

## Consequences

- Backends ship: JSON-RPC (EVM), Blockscout, SQD Portal, Solana, Tron, Aztec, Canton, and a
  stub. Reference implementations live in `lib/`, and no mocking library is used.
- Rate-limit buckets and the cache are local to each node, so a fleet of N nodes spends N times
  the upstream budget.
- Free upstream sources can change terms, so the fallback chains are load-bearing.
- The dated upstream survey (`docs/proposals/web3-upstream-survey.md`) was removed. Each
  backend's moduledoc keeps the probe results it depends on, and the survey is in git history.

# raxol_web3

Pre-alpha and not published to Hex. This is the indexer-agnostic, read-only chain layer described
in [ADR-0033](../../docs/adr/0033-web3-data-surface.md),
[ADR-0038](../../docs/adr/0038-guarded-outbound-client-evm-rest-backend.md),
[ADR-0039](../../docs/adr/0039-required-callback-set-partial-sources.md) and
[ADR-0040](../../docs/adr/0040-fx-market-data-and-rate-sources.md).

## Outbound path

`Raxol.Web3.HTTP` is the only way out of the package. Its pipeline is fixed:

    vet -> cache -> circuit breaker -> token bucket -> pinned dial -> bounded read -> redact

- `Raxol.Core.Outbound` vets the target (`https` only, with a reject set for private addresses).
- `Raxol.Web3.Dial` connects only to vetted `:inet` address tuples. The hostname is used for SNI
  and certificate checks and is never resolved again.
- `Raxol.Web3.Exchange` bounds the size, `content-length`, total deadline and per-`recv` silence.
  A truncated response is never a success.
- `Raxol.Web3.Cache` keys on `{origin_id, fragment}` built from declared parameters, never from
  the URI, so no API key enters a key. `Raxol.Web3.TTL` holds per-endpoint TTLs and never caches
  a height.
- `Raxol.Web3.Tables` owns the ETS tables. `Raxol.Web3.Origin` mints opaque origin ids, so error
  terms never name a host. `Raxol.Web3.Redact` strips query strings and collapses transport
  errors to atoms.
- `Raxol.Web3.RPC` is the read-only JSON-RPC client, with a compile-time method allowlist.
  `Raxol.Web3.MCPCall` is one stateless MCP `tools/call`. Stateful MCP upstreams use
  `Raxol.MCP.Client`.

## Contract and routing

`Raxol.Web3.Backend` has two required callbacks (`chain_info/1`, `block_height/1`) and twelve
optional ones declared through `capabilities/1`. Heights name their unit and carry a finalized
height. Accounts are opaque tagged references. Cursors (`Raxol.Web3.Cursor`) are opaque, carry a
MAC and are bound to their scope.

`Raxol.Web3.Router` picks a healthy backend for each callback and fails over:

- A source error (breaker open, transport, timeout, rate limit, unhealthy status, undecodable
  body) moves to the next backend.
- A question error (not found, unsupported reference, invalid cursor) is final.
- A paging walk stays on the backend that started it.

`coverage/2` reports which callbacks have a healthy source right now.

## Backends

| Module | Sources | Notes |
| --- | --- | --- |
| `Backend.Blockscout` | Blockscout REST `/api/v2/*` | EVM. Paginated endpoints only. |
| `Backend.JSONRPC` | any EVM node | Partial source and the fallback for chain 4663. |
| `Backend.Solana` | SQD Portal, public RPC | `unit: :slot`. Transactions are read at `confirmed`, accounts at `finalized`. |
| `Backend.Tron` | TronGrid MCP, SQD Portal, TronScan MCP | Finalized height from the irreversible view. Base58 and hex canonicalized. |
| `Backend.Canton` | Splice Scan, ccscan | Party ids and rounds. No `get_block/2`. |
| `Backend.Aztec` | aztecscan | Public state only. |
| `Backend.Stub` | in memory | Reference backend for tests. `:answers` injects results. |

## Surfaces

- `Raxol.Web3.MCP.Tools`: thirteen typed read tools. They are `sensitive: true`, so the server
  needs an authorizer. `raxol mcp`'s stdio authorizer allows them (see
  [ADR-0042](../../docs/adr/0042-lean-on-omp.md)), so a network deployment must supply a
  restrictive one. `raw_request` has no tool. A result is JSON text (amounts, and any integer
  past 2^53, as decimal strings); an error is `Error: {"code", "detail", "hint"}`, with
  `"chains"` on `no_backend`.
- `Raxol.Web3.MCP.FXTools`: `web3_fx_stables`, `web3_fx_stable`, `web3_fx_corridors`. Also
  `sensitive: true`, because they spend the operator's Sleuth key and RPC budget, and the same
  authorizer caveat applies.
- The agent tool is `Raxol.Agent.Actions.Web3` in `raxol_agent`: one tool with an `operation`
  enum.

## FX

`Raxol.Web3.FX.Chainlink` is the rate of record. It checks the feed identity, freshness and, on
Base, the sequencer. EUR reads Base and falls back to Ethereum, CHF reads Ethereum, and USD is
exactly 1. `FX.Sleuth` supplies market data under a bearer key that never reaches a URL or a log.
`FX.Quality` judges each asset against the Chainlink rate: `:yield_bearing`, `:no_rate`,
`:suspect` or `:ok`. Callers supply the RPC URLs and the key, and the package reads no
environment. Treat RPC URLs as secrets, since they can carry credentials: `inspect/1` never
renders them, and neither should callers.

## Tests

`mix test` excludes the live tests. `mix test --include live_web3` runs every backend against the
real upstreams. The Canton suite skips its credentialed half when no ccscan key is set.

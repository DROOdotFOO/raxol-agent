# ADR-0038: Guarded outbound client and the EVM REST backend

## Status

Accepted, 2026-09-13. Implemented 2026-09-14 in `packages/raxol_web3`. The required callback
set and the `token_balances` cursor were changed by
[ADR-0039](0039-required-callback-set-partial-sources.md).

## Context

ADR-0033 §7 requires one guarded client for every outbound call: `https` only, a reject set for
private addresses, the vetted address pinned for the dial, no redirects, and bounded size and
time. Req and Finch resolve the hostname again at connect time (which allows DNS rebinding), and
nothing below them bounds the header phase or the total size.

## Decision

1. `Raxol.Core.Outbound` vets targets (scheme and reject set) and returns the checked addresses.
2. `Raxol.Web3.HTTP` is the only module in the package that opens a socket. Its pipeline is
   fixed: vet, cache, circuit breaker, token bucket, pinned dial, bounded read, redact. The
   breaker runs before the bucket, so a refused call spends no budget.
3. `Raxol.Web3.Dial` takes only `:inet` address tuples, never names, and passes the hostname to
   Mint for SNI and certificate checks. It cannot resolve a name again.
4. The bounded read (`Raxol.MCP.BoundedExchange`, with `Raxol.Core.Outbound.Response` as the
   accumulator) enforces a size ceiling, refuses a `content-length` over that ceiling, and applies
   a wall-clock deadline and a per-`recv` timeout. The accumulator starts as `:incomplete`, so a
   truncated response can never look like success.
5. `Raxol.Web3.Supervisor` owns the ETS tables for buckets, breakers and the cache, keyed per
   origin, because a table dies with the process that created it. A `403`, `408`, `429`, `5xx`,
   transport error or timeout counts as a breaker failure. Cache keys are built by allowlist from
   the parameters an endpoint declares, never from the request URI, so a key-bearing query
   parameter cannot enter a key. Per-endpoint TTL values are left to the implementation
   (`Raxol.Web3.TTL`), except for the height-bearing routes, which decisions 5 and 7 settle
   together: a height is never cached, because a cached height read beside a live finalized
   height breaks the monotonicity of `block_height/1`.
6. Redaction is a module (`Raxol.Web3.Redact`), with four rules: no upstream response body in an
   error term; no URL with a query string in a log line or error term; a key-bearing query
   parameter is stripped before a URI is rendered; and no caller-influenced host in an error
   term, so errors name an origin by id. Errors form a closed set: `{:blocked, _}`,
   `{:dns_failed, _}`, `{:rate_limited, ms}`, `{:breaker_open, _}`, `{:too_large, _}`,
   `{:timeout, _}`, `{:transport, _}`.
7. The Blockscout EVM backend calls only paginated REST endpoints and declares what REST cannot
   answer. `token_balances/2` uses `/api/v2/addresses/{hash}/tokens`, not the unpaginated
   `/token-balances`, which returned 3.1 MB for one wallet when probed.
8. Cursors are versioned and Base64url-encoded, bound to their origin and endpoint, and carry a
   MAC under `config :raxol_web3, :cursor_key`. A fleet must share a key of at least 32 bytes.
   A malformed key is a boot error. Decoded keys are also checked against a per-endpoint
   allowlist.
9. Every request sends `User-Agent: raxol_web3/<version> (+https://raxol.io)`, and a caller
   cannot override it (Mint would otherwise send its own). A refusal counts as a health signal:
   a `403` challenge page is a breaker failure and leads to failover, never to a retry with a
   different UA. What a `200` body means (an error inside a success, as Etherscan returns) is
   the backend's judgement, not the client's.
10. Dependencies: `mint` and `castore`, with no `req` or `finch`.

## Consequences

Mitigations:

- Every upstream figure that is a guess rather than a measurement (rate limits, TTLs) is labelled
  as a guess where it is configured.
- The chain-to-host table is data with a dated comment saying when each endpoint was probed.

Effects:

- SSRF and DNS rebinding are prevented by the structure of the code, not by convention.
- Buckets are local to each node, so N nodes spend N times the upstream budget.
- `Raxol.Web3.Supervisor` refuses to boot if the shared bounded read cannot be loaded, because
  `mint` is optional in `raxol_mcp` and required here.

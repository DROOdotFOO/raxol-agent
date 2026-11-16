# Canonical ramp/1 artifacts

`contract.schema.json` and `conformance.json` are copied without edits from
[xochi-fi/xochi-sdk](https://github.com/xochi-fi/xochi-sdk), branch
`feature/ramp-onramp`, commit `367f3185943672af1b7c227fd608ba7f7fd39aad`:

- `packages/client/ramp/contract.schema.json`
- `packages/client/ramp/conformance.json`

The runtime schema in `priv/ramp/contract.schema.json` is an identical copy.
The Elixir binding validates this schema plus the semantic invariants from
`packages/client/src/ramp.ts` at that commit. Tests cover every vector, including
command preflight (validation only, no execution).

## Peer response fixtures

`peer_quote.json` is a synthetic, sanitized positive response based on the
`BestByPlatformResponse` / `QuoteSingleResponse` definitions and adapter source
in the published `@zkp2p/sdk@0.15.0-rc.11` tarball, the exact SDK version pinned by
`examples/peer-compatibility/package.json` at the commit above. It contains no
maker identifiers, order/deposit/session handles, payment identity, or proof data.
Its recipient and orchestrator addresses are deliberately synthetic. It is not
represented as a successful live capture.

`peer_failure_recording.json` records the public quote endpoint's HTTP 400 response
observed on 2026-11-16 from this Linux host. The response body was discarded in
memory and replaced by an empty string before recording. The request used no
credentials and a synthetic wallet. A successful live quote remains unverified;
replace/add a sanitized success recording after an operator obtains live access.

API evidence (consulted 2026-11-16):

- https://docs.peer.xyz/developer/sdk/client-reference#quote-api
- https://docs.peer.xyz/developer/integrate-zkp2p/integrate-redirect-onramp
- `@zkp2p/sdk@0.15.0-rc.11`, `src/adapters/api.ts` (via published source map):
  `apiGetQuotesBestByPlatform`, `QuotesBestByPlatformRequest`,
  `BestByPlatformResponseObject`, `QuoteSingleResponse`.

The public read-only endpoint is `POST https://api.zkp2p.xyz/v3/quote/best-by-platform`
(or `best-by-platform-exact-token`). Both request modes use token base units;
USD cents are multiplied by 10,000, and returned fiat is divided exactly by
10,000. A fractional cent is rejected, never rounded.

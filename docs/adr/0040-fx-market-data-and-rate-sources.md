# ADR-0040: FX market data and rate sources

## Status

Accepted, 2026-09-30. Decisions 1 to 6 implemented 2026-10-01. Decision 7 is not built: spend
caps refuse EURC, EURe and ZCHF sources unless the policy's currency matches their peg (then
they are counted at par). WETH and RAXOL sources are priced in USD by
`Raxol.Payments.SpendPricing`.

## Context

The FX dark pool needs non-USD stablecoins. Before this ADR, `SettlementLedger` valued every
stablecoin at par, nothing priced EUR or CHF tokens, and an unpriced leg disappeared from totals
without a trace. Sleuth publishes stablecoin market data. Chainlink publishes EUR/USD and CHF/USD
feeds.

## Decision

1. FX is market data in `raxol_web3` (`Raxol.Web3.FX.*`). It is not a `Raxol.Web3.Backend` and
   has no source behaviour. Tests drive the real handles over recorded fixtures through
   `Raxol.Web3.HTTP`'s `:exchange` option.
2. Chainlink is the rate of record (`FX.Chainlink`, `latestRoundData()` over
   `Raxol.Web3.RPC.eth_call/4`, RPC URLs from config). USD is exactly 1. EUR reads Base and falls
   back to Ethereum. CHF reads Ethereum only. Any other peg is `:no_rate`. A rate is usable only
   if: `answer > 0`; it is no older than the feed heartbeat × 1.1; on Base, the sequencer is up
   and has been up for at least 3,600 s; and `description()` and `decimals() == 8` match. A
   mismatch is `{:blocked, :feed_mismatch}`, and the result is terminal. A rate carries its
   `precision_bps` (10 on Base, 15 on Ethereum).
3. Sleuth (`FX.Sleuth`) goes through the guarded client. It uses a bearer header only, never
   `?api_key=`, with a token bucket of 5 and refill 0.25/s, a 60 s cache, and a 256 KiB body
   bound. It decodes with `floats: :decimals`, with bounded figure sizes, list caps and filtered
   text. Arguments are validated before any request is built. No upstream body leaves the
   module.
4. `FX.Quality` computes the verdict itself from the Chainlink rate and never relays Sleuth's.
   The first matching status wins: `:yield_bearing`, `:no_rate`, `:suspect` (|deviation| >
   100 bps), `:ok`.
5. Surfaces: MCP tools `web3_fx_stables`, `web3_fx_stable` and `web3_fx_corridors`, which are
   read-only and sensitive. One agent `fx` tool, gated by `Policy.Grants.network_allow/1`. The
   configuration (`:raxol_agent, :web3` plus `RAXOL_SLEUTH_API_KEY`) is read once at boot. A bad
   value refuses the boot and names the problem, never the key.
6. Valuation in `raxol_payments`:
   - `Assets` registers EURC, EURe and ZCHF in a separate `@fx_stables` table, not in the
     solver-fillable `@evm_tokens`. `Assets.fx_peg/2` names a token's peg.
   - Registering a token must not open a fund-moving path. Xochi, Relay, the deposit route and
     x402 refuse an FX source with `{:unpriced_asset, _}`. They accept an FX destination only
     with a positive `min_to_amount` in the destination's units, read through
     `DeliveryFloor`.
   - `Prices.FX` prices the registered symbols at the Chainlink rate. Sleuth can only veto.
     Other symbols fall through to `RAXOL_PRICE_SOURCE`. Enabled by `RAXOL_FX_ENABLED=true`.
   - `SettlementLedger` counts `unpriced_count` instead of dropping unpriced legs.
   - `raxol_web3` is an optional dependency of `raxol_payments`.
7. Deferred: a spend cap, delivery floor or fee base may convert an FX amount only when the rate
   is usable, the Quality is `:ok` with |deviation| ≤ 25 bps, and the Sleuth snapshot is younger
   than 60 s. Sleuth alone never gates.

## Consequences

- Non-USD stablecoins are visible and priced in accounting, but they cannot move money until
  decision 7 is built.
- Every refusal names its reason, and every unpriced leg is counted.

# Changelog

All notable changes to `raxol_payments` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - Unreleased

### Changed

- **Breaking: `Raxol.Payments.Secret` is deprecated** and delegates to
  `Raxol.Agent.Secret` (raxol_agent); `new/1` returns a `Raxol.Agent.Secret`,
  so a `%Raxol.Payments.Secret{}` pattern no longer matches.
  `Accounting.env_config/0` returns its RPC URLs wrapped. Hence 0.4.0.
- **Breaking: `Xochi.Stealth.derive_keys/1` returns each private key
  `Raxol.Agent.Secret`-wrapped** (`{secret, public_key}`). `scan/3` takes raw
  or wrapped keys, runs under `with_revealed/2` (a raise becomes `{:error,
  :secret_operation_crashed}`), and returns `{:error, :invalid_announcements}`
  for a non-list instead of raising.
- `Xochi.Client` accepts a wrapped token in `auth: {:member, _}`;
  `protect_config/1` wraps raw member tokens for a caller about to keep the
  config. `Relay.Client` and `Pxe.Client` accept a wrapped token or key; a
  `nil` relay token sends no `authorization` header (was `Bearer `).
- `ChainReader.JSONRPC` and `Accounting.env_config/0` keep RPC URLs wrapped,
  since provider URLs embed API keys.
- Requires `raxol_agent ~> 3.2` (was `~> 3.0`), the release that ships
  `Raxol.Agent.Secret`.

### Added

- The Xochi status parsers read every `IntentLifecycleStatus` of
  `@xochi/spec` 0.14.0. `IntentStatus` and `Intent` add `:pull_pending`,
  `:source_finalized` and `:refund_pending`; `ExecuteResponse` adds those and
  `:bridging`, `:expired` and `:refunded`. They parsed as `:unknown`, so an
  execute answering one was treated as in doubt. `:source_finalized` and
  `:refund_pending` stay non-terminal even when the server flags them
  terminal: `PollXochiStatus` keeps polling and keeps the reservation through
  `refund_pending`, and releases it at `refunded`.

### Changed

- **Breaking.** `ExecuteRelayTransfer` reports a transfer whose funding is in
  doubt as `{:ok, %{transfer_id: id, status: "unknown", reconciling: true,
  ...}}`, as `ExecuteXochiIntent` does, instead of a `:stranded` `Failure`
  with detail `{:in_doubt, transfer_id}`. The reservation stays tagged with
  the transfer id and the checkpoint stays, so a re-run returns the same
  result without signing or sending again. Every result carries
  `reconciling`. `Failure.from({:in_doubt, transfer_id})` is removed.
  Upgrade: match `reconciling: true` on the `:ok` result and poll the transfer
  with `PollRelayStatus` instead of matching the error.

### Fixed

- The structs returned by public functions are documented:
  `Xochi.Schemas.QuoteResponse`, `ExecuteRequest`, `ExecuteResponse` and
  `IntentStatus`; `Relay.Schemas.QuoteRequest`, `QuoteResponse`,
  `ExecuteRequest` and `StatusResponse`; `Pxe.Schemas.HealthStatus`. `mix docs`
  builds without warnings.

## [0.3.0] - 2026-11-14

### Upgrading from 0.2

0.3.0 breaks 0.2, and a `~> 0.2` requirement resolves to it; pin `~> 0.2.1`
to stay on 0.2. Each change below needs action from a 0.2.1 user; the entry
named in parentheses describes it and is marked **Breaking**.

- Pass a `SpendingPolicy` to `Req.AutoPay.attach/2`,
  `Req.AgentPlugin.auto_pay/1` and the Xochi `{:x402, opts}` auth; a
  non-finite cap is refused (Changed, "`AutoPay.attach/2` ... require
  `:policy`").
- Caps are human amounts of the policy's currency for every protocol, a
  custom `Protocol` sets `:unit` in its parsed challenge, and
  `Ledger.get_totals/3` takes only a `SpendingPolicy` (Changed, "Every
  `SpendingPolicy` cap").
- `SpendGate.authorize/3` requires `asset:` and returns `{:ok, amount}`; pass
  that amount to `release/3` and `tag_reservation/3` (Changed, "`SpendGate`
  converts every spend").
- Spending a token that is not a stablecoin needs a price source (`:price_fn`
  or `price_source:`), and `Prices.Static` and `Prices.CoinGecko` prices
  expire after 300 seconds (same entry).
- `SpendGate` enforces `per_request_max` without a `:ledger`, and refuses an
  unusable policy as `{:invalid_policy, field}` (Changed, "`SpendGate`
  applies the policy's `per_request_max`").
- EURC, EURe and ZCHF are spent only under a policy in their own currency
  (Added, "`ExecuteXochiIntent`, `ExecuteRelayTransfer`, `payment_transfer`
  and ACP buys").
- A deployed release requires a solver pin for ERC-3009 origin pulls
  (Changed, "`:pull_require_solver_pin` defaults").
- AutoPay keeps a signed spend recorded when the paid retry fails, and an
  x402 `validBefore` is at most one hour out (Security, "`Req.AutoPay` keeps
  the spend recorded").
- A served EIP-712 payload must be the canonical typed data, and
  `EIP712.hash/3` returns `{:error, :no_primary_type}` for a types map without
  a single root (Security, "Every EIP-712 payload").
- `Pxe.Client` follows the pxe-bridge contract: idempotency keys, new results
  and errors (Changed, "`Raxol.Payments.Pxe.Client`").
- The Riddler Commerce API client is removed (Removed, "The Riddler Commerce
  API client").
- `Protocols.Xochi.execute/3` and `sign_intent/2` are removed; use `execute/4`
  and `sign_intent/3` (Removed).
- In `{:delivery_below_floor, detail}`, `min_to_amount` is the quote's own
  minimum and `:floor` the caller's (Changed, "`{:delivery_below_floor,
  detail}`").
- `PrivacyTier`'s `data_retention` no longer has `:nothing` (Changed,
  "`Raxol.Payments.PrivacyTier`").
- EURe leaves `Assets.symbols/0` and `evm_tokens/0` (Added,
  "`Raxol.Payments.Assets` registers the non-USD stablecoins").
- A custom `Relay.Broadcaster` returns `{:error, {:not_sent, reason}}` for a
  failure before submission; any other error leaves the Relay spend reserved
  as in doubt (Security, "`ExecuteRelayTransfer` keeps the spend").
- Requires `decimal ~> 3.1`, whose default context differs from decimal 2's,
  and `req ~> 0.6` (Security, "Requires `decimal`" and "Requires `req`").
- Requires `raxol_agent ~> 3.0` and `raxol_core ~> 2.8` (Changed, "Requires
  `raxol_agent`").
- A release that depends on `raxol_payments` from Hex starts `raxol_agent`,
  `raxol`, `raxol_mcp` and `raxol_journal` (Changed, "A release that depends
  on `raxol_payments`").

### Added

- `Raxol.Payments.Protocols.Xochi.origin_pull_pin_env_config!/0`: reads the
  origin-pull solver pin from `XOCHI_SOLVER_ETH`, `_BASE`, `_ARBITRUM`,
  `_OPTIMISM`, `_POLYGON`, `_ROBINHOOD` and `XOCHI_PULL_REQUIRE_SOLVER_PIN`
  (unset: required in production), raises when the
  result is fail-open, and returns the keyword list for
  `config :raxol_payments` (the configured addresses plus
  `PullContracts.pull_recipients/0`). For the `config/runtime.exs` of a release
  that signs origin pulls.
- Xochi read capability. `ExecuteResponse.read_token` carries the
  one-time token `POST /api/intent/execute` returns (nil from an older worker;
  excluded from `inspect`). `Xochi.Client.get_status/3` and `get_intent/3` take
  `read_token:` and send it as the `X-Xochi-Read-Token` header, never in the
  URL. Protocol-level callers may forward it in memory.
- The payment Actions never expose the raw capability to the model or replay
  summary. `payment_execute_xochi_intent` stores a `Secret`-wrapped token in a
  separate checkpoint record keyed by canonical API origin
  (`scheme://host[:port]`), executing principal, and intent id.
  `payment_poll_xochi_status` requires the matching ownership checkpoint before
  a model-triggered poll can read or present it. Without a checkpoint configured,
  polling remains anonymous.
- `IntentStatus` parses `settlement_tx_hash`, `settlement_chain_id`, and the
  anonymous view's `settlement_confirmed` / `legs_withheld` markers
  (`IntentStatus.settlement_confirmed?/1`). `payment_poll_xochi_status`
  reports them and `receiving_tx_hash` in its summary. Every terminal result is
  committed before its read token is deleted. The terminal summary is replayable
  for 24 hours; tokens expire after one hour. Failed, expired, and refunded
  results delete the token too. A poll that times out on a confirmed but
  non-terminal fill returns a `terminal: false` summary instead of
  `:stranded`; the `intent_stranded` telemetry carries the last status and
  `legs_withheld`. Neither marker releases, refunds, or re-executes anything.
- `Raxol.Payments.Poll.run/3` takes `last_status_on_timeout: true` to return
  `{:error, {:timeout, last_status}}`.
- Read tokens accept both the existing camelCase and supported snake_case JSON
  keys. A served token that is not 43 unpadded base64url characters produces a
  redacted, contextual in-doubt error; a caller token of the wrong shape is
  refused before any request. Token-bearing reads never follow redirects.
- Checkpoint stores expose atomic `put_new/3` acquisition. Concurrent settlement
  attempts for the same intent have one writer and cannot delete the winner's
  state.
- Execute connection setup failures that prove no request was sent (invalid URL,
  DNS failure, refused/unreachable connection, connect timeout, and TLS
  handshake failure) release the checkpoint and spend reservation. Ambiguous
  transport/reset, malformed response, and 5xx outcomes remain reconciling under
  the known intent id. A 502 is therefore not a clean failure. A refused execute
  (409, or 400 saying another writer completed or claimed the intent) is a clean
  rejection for this writer and is never converted into a deliverable by polling
  that intent. For a genuinely ambiguous dispatch, a 404 at or after the signed
  deadline proves it never landed and releases the reservation.

- Registered RAXOL on Robinhood Chain (`0xf447...53af`, 18 decimals) in
  `Raxol.Payments.Assets`, so the Xochi client sizes, resolves and classifies
  USDC/USDT/USDG->RAXOL legs.
- `Raxol.Payments.Prices.CoinGecko` prices EURe (USD quote, not dollar par),
  RAXOL and WETH. Neither EURe nor RAXOL is a settlement-ledger stablecoin, so
  an unpriced leg reports `nil`, never $1. New `Raxol.Payments.Prices` reads
  the configured `price_source:` and `fx:`, and new `Assets.peg/2` and
  `Assets.symbol_peg/1` name a stablecoin's peg currency, the dollar included.
- `Assets.parse_atomic/1` parses a positive atomic amount no wider than a
  uint256, and `Assets.to_decimal/1` converts an amount to a `Decimal`, taking
  an integer string of up to 78 digits through the integer (decimal 3's
  string parse stops at 34 digits).
- **Breaking.**
  `Raxol.Payments.Assets` registers the non-USD stablecoins of ADR-0040:
  EURC on 1 and 8453, EURe on 1, 100, 137, 8453 and 42161, and ZCHF on 1 plus
  the CCIP-bridged contract on 10, 100, 137, 8453 and 42161, each at its
  on-chain decimals. EURe was previously registered on 1 and 42161 only, so
  elsewhere the lenient `decimals/2` scaled it at 6 instead of 18, off by
  10^12. `address/2` matches the mixed-case wire symbol `"EURe"`
  case-insensitively. EURe's legacy v1
  contracts resolve to `"EURe"` through `symbol_for/2` and are never returned
  by `address/2`, since they front the same balance as v2. Chain 100 (Gnosis)
  gains a name and its xDAI gas token. New `Assets.fx_peg/2` names a token's
  non-USD peg. None of these tokens is solver-fillable: EURe leaves
  `symbols/0`, `evm_tokens/0` and the Xochi settlement grid, where it was
  listed on Arbitrum. `Xochi.Capabilities.fallback/0` and the capacity
  deriver read `evm_tokens/0`, so they drop EURe on 42161 too; only
  `supported_chain_ids/0` and the stealth chain check are unchanged.
- **Breaking.**
  `ExecuteXochiIntent`, `ExecuteRelayTransfer`, `payment_transfer` and ACP
  buys spend one only under a policy in its own currency (a EUR policy counts
  EURe at par) and otherwise refuse it as
  `{:unpriced_asset, %{reason: :fx_unsupported}}` (see Changed),
  and Xochi and Relay refuse a non-USD destination without a positive
  `min_to_amount`, as `{:unpriced_asset, detail}` (ADR-0040 decision 6),
  until an FX rate gates the conversion (decision 7). A `min_to_amount` of `0`
  bounds nothing: Relay and the deposit route read it as absent and Xochi
  refuses it. x402 pays only in registered USDC (see Security), so it refuses
  a non-USD stablecoin challenge at parse, as `{:unpriced_asset, detail}`.
- `ExecuteRelayTransfer` accepts `min_to_amount` and refuses a quote delivering
  less before the spend is authorized. It previously had no delivery floor, so
  a quote could deliver any amount.
- `ExecuteXochiIntent`'s delivery floor also judges the `toAmount` in the
  EIP-712 message the wallet would sign, read only when the message's primary
  type declares the field. A null or missing value counts as 0, which is what
  `EIP712` signs, and a whitespace or sign variant fails closed at the floor or
  the encoder, so a quote whose signed amount is 0 is refused.
- `Raxol.Payments.TypedData` checks a served EIP-712 payload against the
  canonical typed data for one message kind: `check_shape/2` (primary type,
  types, `typeHash`, message fields) and `check_domain/2` (exactly the
  expected domain fields and values).
- `EIP712.type_hash/2` returns the `typeHash` of a struct type, and
  `EIP712.hash/4` hashes the primary type the caller names.

- Euro and franc stablecoins can be priced in accounting (ADR-0040 decision 6).
  `RAXOL_FX_ENABLED=true` with `RAXOL_SLEUTH_API_KEY` and `RPC_BASE` or `RPC_ETH`
  puts `Raxol.Payments.Prices.FX` in front of `RAXOL_PRICE_SOURCE` in the
  `RebalanceMonitor` sweep and `mix raxol_earn.rebalance`: EURC, EURe and ZCHF
  are priced at the Chainlink rate for their peg when Sleuth's market price is
  within 100 bps of it, and `nil` otherwise. Enabling it without the key, without
  either RPC URL, or in a build without `raxol_web3` (an optional dependency,
  dropped under `HEX_BUILD`) refuses and names what is missing. Pricing only: no
  spend cap or delivery floor reads an FX rate. `Prices.FX` answers exactly
  the symbols in `Assets.fx_pegs/0`, in any casing, at the Chainlink rate for
  the peg registered there, and hands every other symbol to
  `RAXOL_PRICE_SOURCE`. A listing whose peg disagrees with the registered one,
  a symbol listed twice with any listing not `:ok`, a symbol missing from the
  snapshot, and a failed snapshot leave the symbol `nil`, never the fallback.
  A key `Raxol.Web3.FX.Sleuth.new/1` refuses (one with a CR, LF or space
  inside it) is logged, naming the argument and never the key, and leaves
  EURC, EURe and ZCHF unpriced for the sweep to count.
- `SettlementLedger` aggregates carry `unpriced_count` and
  `recording_gap_count`. A leg or a nonzero fee that neither `usdc_price` nor
  `price_fn` could price (an EURe fee) used to drop out of `usd_revenue` or
  `usd_fee` without a trace, so a report with EUR legs read as smaller rather
  than as partial; such an entry now counts once in `unpriced_count`. An entry
  missing a leg's amount or decimals is a recording problem, not a pricing
  one: it counts in `recording_gap_count`, and in `unpriced_count` only when
  its fee, its margin basis, is unpriced.
- Each `RebalanceMonitor` sweep reports margin. It prices
  `SettlementLedger.report/2` with the same `price_fn` that sizes refuels (FX
  in front of `RAXOL_PRICE_SOURCE` when enabled), emits the totals as
  `[:raxol, :payments, :margin]`, which the accounting sidecar logs as
  `payments.margin`, and keeps the per-corridor report for
  `RebalanceMonitor.margin_report/1`. Until now nothing in production read the
  report, so FX pricing reached only the native gas symbols a refuel asks for.
  The advice and the report fail independently, and an FX snapshot that raises
  leaves EURC, EURe and ZCHF unpriced, and the rest to `RAXOL_PRICE_SOURCE`,
  instead of aborting the sweep.
  `SettlementLedger.report/2` reads the ledger once instead of four times.
  `SettlementLedger` aggregates and the event carry `margin_count`, the number
  of entries `usd_margin` covers, and `gas_unpriced_count`, the entries whose
  gas amount is known but whose gas symbol no price answers (POL with a price
  source that only knows ETH); `count - margin_count` is every entry left out
  of `usd_margin`, for any reason. The event carries `unpriced_count` and
  `recording_gap_count` too.
- Xochi quotes can be exact-output. `QuoteRequest` gains `swap_kind`
  (`"exact_input"` by default, or `"exact_output"`), `output_amount` and
  `max_from_amount`; an exact-output request sends `output_amount` instead of
  `from_amount` and never sends `max_from_amount`, which only caps what raxol
  will sign. `ExecuteXochiIntent` takes `swap_kind` and `output_amount`; on
  exact output `amount` is the maximum spend, reserved by the spend gate and
  passed on as `max_from_amount`. Exact output has no automatic same-asset
  floor; an explicit `min_to_amount` still applies.

### Changed

- **Breaking.** Requires `raxol_agent ~> 3.0` (was `~> 2.7`) and
  `raxol_core ~> 2.8` (was `~> 2.7`).
- **Breaking.** A release that depends on `raxol_payments` from Hex includes
  and starts `raxol_agent` and the applications under it: `raxol`,
  `raxol_mcp` and `raxol_journal`. 0.2.1 declared `raxol_agent`
  `runtime: false`, which left it out of a consumer's release, so the payment
  Actions raised at run time. `raxol` boots in `:full` mode unless
  `RAXOL_MODE=minimal` (or `config :raxol, :startup_mode, :minimal`), which
  starts only its error recovery, event manager and telemetry (when enabled).
  `raxol_agent` starts `Raxol.Agent.Supervisor` (its MCP agent tools register
  only on an `:mcp` node or with `config :raxol_agent, :mcp_tools, true`) and
  refuses to boot on a malformed `config :raxol_agent, :web3`.
- **Breaking.** `Raxol.Payments.Req.AutoPay.attach/2`,
  `Req.AgentPlugin.auto_pay/1` and the Xochi client's `{:x402, opts}` auth
  require `:policy`, a `SpendingPolicy`, and raise `ArgumentError` without
  one. Without a policy AutoPay used to pay any 402 with no domain or amount
  gate. Every payment is now held to the policy's `approved_domains`,
  `require_confirmation_above` and `per_request_max`, with or without a
  `:ledger`; its `session_max` and `lifetime_max` are enforced only with a
  `:ledger`. An amount over `per_request_max` is refused before signing with
  the same `%{error: :budget_exceeded, limit: :per_request}` body either way.
  Pass `SpendingPolicy.dev()` for development. New
  `Raxol.Payments.Ledger.check_request/2` is the per-request check without a
  ledger. `attach/2` also raises when `per_request_max` (and, with a
  `:ledger`, `session_max`, `session_window_ms` and `lifetime_max`) is not a
  finite positive value.
- **Breaking.** Every `SpendingPolicy` cap is a human amount of the policy's
  `currency` (`SpendingPolicy.unit/1`, US dollars for the default `"USDC"`),
  for every protocol. `MPP.amount/1` returned the challenge's atomic amount,
  so an MPP charge of 5 USDC base units was gated as $5; it now scales by the
  challenge currency (ISO 4217 minor units for USD, EUR and CHF, registered
  decimals for a dollar or registered non-USD stablecoin), and a challenge in
  any other currency is refused at parse (`{:unpriced_currency, currency}`);
  AutoPay passes such a challenge through as the unpaid 402 and logs the
  refusal. A parsed challenge carries its `:unit`; AutoPay refuses one whose
  unit is not the policy's (`%{error: :currency_mismatch}`) before anything is
  reserved, so MPP and x402 payments add up against the same caps. A
  custom `Protocol` must set `:unit` in its parsed challenge. The Ledger
  refuses a non-`SpendingPolicy` or a nil or non-finite cap as
  `{:over_limit, :invalid_policy}` instead of crashing, and `get_totals/3`
  takes only a `SpendingPolicy`. New `SpendingPolicy.validate/2`.
- **Breaking.** `SpendGate` converts every spend into the policy's unit
  before the policy gate, the ledger reservation and any signature
  (`Raxol.Payments.SpendPricing`). It used to reserve the source token's own
  amount, so a 5 WETH Xochi intent counted as 5 against a $10 cap. Now a
  stablecoin pegged to the unit counts at par (USDC, USDT, USDG, DAI and Tron
  USDT/USDC under a USD policy), and under a USD policy any other token
  (WETH, RAXOL) counts at its USD price from the context's `:price_fn` or
  `config :raxol_payments, :accounting, price_source:` (`RAXOL_PRICE_SOURCE`
  when accounting is enabled). Non-pegged sources need a price source under
  a policy: with none, with no fresh positive price, or with a source that
  raises, the spend is refused as `{:unpriced_asset, %{reason: reason}}`
  before anything is signed. `Prices.CoinGecko` asks for each price's
  `last_updated_at` and answers `nil` for one older than `:max_age_s`
  (default 300 seconds) or without one; `Prices.Static.price_fn/2` takes
  `:as_of` (default when built) and `:max_age_s` (default 300) and answers
  `nil` once its prices are older. For a spend the configured source is
  fetched without retries and with 5-second connect and receive timeouts, and
  a failed fetch refuses the spend as `:price_source_error`, which is
  retryable (`Prices.source_fn/2` passes options to
  `Prices.CoinGecko.price_fn/1`, which takes `:raise_on_fetch_error`); the
  accounting sweep keeps the defaults. No spend cap reads an FX rate, so a
  stablecoin pegged to another currency is refused (EURC, EURe and ZCHF
  under a USD policy or with no policy; a dollar stablecoin under a EUR or
  CHF policy), and under a non-USD policy every token not pegged to it is
  refused. `SpendGate.authorize/3` requires `asset:` (`{:token, chain_id,
  address}` or `{:symbol, ticker}`) and returns `{:ok, amount}`, the
  converted amount the caps saw and the ledger holds; pass it to
  `release/3` and `tag_reservation/3`. The ledger entry's `currency` is the
  policy's, and its metadata keeps `source_asset` and `source_amount`.
  `payment_transfer` returns `reserved`. An unregistered Relay source token,
  which was scaled at 6 decimals, is refused, with or without a policy.
- **Breaking.** `SpendGate` applies the policy's `per_request_max` without a
  `:ledger` too (`Ledger.check_request/2`, as AutoPay does). It used to skip
  every cap when no ledger was in context, so a policy alone bounded only the
  approved domains and the confirmation threshold. A policy whose
  `per_request_max` (and, with a ledger, `session_max`, `session_window_ms`
  or `lifetime_max`) is not usable, or that is not a `SpendingPolicy`, is
  refused before pricing as `{:invalid_policy, field}`, a `:config_error`
  failure; with a ledger it was reported as `{:over_budget, :invalid_policy}`.
- **Breaking.** `config :raxol_payments, :pull_require_solver_pin` defaults to
  `Raxol.Payments.Deployment.production?/0` (was `false`): a deployed release
  with no `:pull_solver_allowlist` rejects an unpinned ERC-3009 origin pull
  before signing. An explicit `true` or `false` still wins.
- Cross-repository parity now uses the published `@xochi/spec@0.14.0`
  tarball, pinned by committed SHA-512 integrity and fetched through a cached,
  verified script. `XOCHI_SPEC_DIR` is the single package-root contract, and
  `RIDDLER_CHECKOUT_DIR` explicitly names any built Riddler checkout.
- **Breaking.**
  `Raxol.Payments.PrivacyTier`: Sovereign's `data_retention` is `:wallet`, not
  `:nothing`; `:nothing` is removed from the `t()` typespec. No design promises
  zero retention and Sovereign is excluded. `examples/privacy_modes.exs` /
  `examples/README.md` describe shielded as unavailable: on testnet the
  recipient is private and the amount public (the recipient half is not
  delivered), the production target (conditional) hides amount and recipient
  on Aztec only, and the source deposit is always public. The `PrivacyTier` moduledoc
  marks Private and Sovereign shielded settlement unavailable.
- **Breaking.** `Raxol.Payments.Pxe.Client` now follows the pxe-bridge
  contract. Previously it could not safely move money: there was no
  `Idempotency-Key`, it timed out at 15s while the bridge proves for up to
  120s, and `-32001`/`-32002` arrived as a generic RPC error.
  - `create_note/3` takes an idempotency key (1-128 printable ASCII; one key
    per transfer) and sends it as `Idempotency-Key`.
  - `create_note/3` waits 180s (`:create_note_timeout_ms`) and retries only a
    refused or closed connection, once, never after a timeout. Reads use
    `:request_timeout_ms` (10s).
  - `-32001` is `{:error, :request_in_flight}`. `-32002` is
    `{:error, {:submitted_unknown, tx_hash | nil}}`, carrying `data.txHash`.
    The moduledoc says which failures are safe to resend with the same key.
  - `CreateNoteResult` holds `note_hashes`, `nullifiers` and `l2_tx_hash`.
    `note_commitment` / `nullifier_hash` are removed: the bridge deprecated
    them. `from_json/1` returns `{:ok, t} | {:error, {:unexpected_result, _}}`.
  - `CreateNoteParams` rejects a zero amount and the zero recipient address,
    as the bridge does, and accepts the optional XIP-1 trade context
    (`trade_id`, `sub_trade_index`, `total_sub_trades`; all or none).
  - `health/1` returns a 503 `starting` body as
    `{:ok, %HealthStatus{status: :starting}}`.
  - The `:retry` config key is gone.
  - Modelled on `@xochi/client`'s transport, which uses separate timeouts for
    long writes and reads and retries only idempotent reads on 502/503/504.

- **Breaking.**
  In `{:delivery_below_floor, detail}`, `min_to_amount` is the quote's own
  stated minimum; the caller's floor is `:floor`, and `:lowest` is what was
  compared. In v0.2.1 `min_to_amount` was the caller's floor. The refusal's
  message no longer says "refusing to sign", which was wrong on the deposit
  route.

### Removed

- **Breaking.** The Riddler Commerce API client is gone: Riddler removed
  `/commerce/*` server-side. Deleted `Raxol.Payments.Riddler.Client`,
  `Raxol.Payments.Riddler.Schemas` (and its `QuoteRequest`/`QuoteResponse`/
  `OrderRequest`/`OrderStatus`/... structs), `Raxol.Payments.Protocols.Riddler`,
  and the `:riddler` atom in `Raxol.Payments.Protocol.resolve/1`. Use
  `Raxol.Payments.Protocols.Xochi` (which `Protocols.Riddler` already
  delegated to) for cross-chain intents. `Raxol.Payments.Relay.Client` is
  unaffected.

- **Breaking.**
  `Protocols.Xochi.execute/3` and `Protocols.Xochi.sign_intent/2`. Use
  `execute/4` and `sign_intent/3`, which take the `QuoteRequest` the quote was
  fetched with.

### Fixed

- A Permit2 intent's execute `nonce` (the worker's replay-dedup key) was
  derived by reading Permit2's decimal uint256 pull nonce as hex: an odd digit
  count sent 0 for every intent, which the worker rejects on the wallet's
  second non-terminal intent ("Nonce already used"). Decimal nonces now give
  their low 48 bits, as 0x-hex ERC-3009 nonces already did.
- raxol signed the Xochi EIP-712 intent without checking it against the
  request. A quote could carry a signable intent for another wallet,
  recipient, chain, token, amount, settlement preference or a far-off
  deadline, and raxol would sign it. `Xochi.validate_intent/2` now checks,
  before any signature, that the served payload is exactly the v3 `XochiIntent`
  (its types, field order and message fields) under the v3 Xochi domain on the
  request's origin chain, and binds every route and amount field to the request, both in
  `sign_intent/3` and in `ExecuteXochiIntent` ahead of the spend gate, so a
  mismatch reserves nothing. A refusal is `{:intent_mismatch, field}`, reported
  as `:rejected`. The reported and telemetry `from_amount` is the signed
  `fromAmount`.
- `ExecuteXochiIntent` signed a re-quote without checking it. When the first
  execute came back as an expired quote (a 409 the endpoint chooses), the
  retry fetched a new quote and signed it with neither the delivery floor nor
  the method check, so a re-quote delivering 1 was signed and executed. The
  re-quote is now held to both before anything is signed; a refusal releases
  the reservation with `reason: :requote_refused` in the ledger entry's
  metadata and reports the refusal itself.
- `EIP712` signed a `uint256` outside 0..2^256 - 1 as its low 256 bits
  (2^256 + 1 signed as 1). It now refuses one, and every amount the delivery
  floor reads, the caller's floor included, must be at most 2^256 - 1.
- `ExecuteDepositRoute` returns `to_amount` and `min_to_amount` as strings
  even when the quote served them as JSON numbers; a numeric `min_to_amount`
  passed the floor and then failed the tool's output schema, so the payer got
  no address.
- `ExecuteXochiIntent`'s 80%-of-par same-asset floor is judged, like any floor,
  on the lowest amount the quote states, so a `slippage_bps` past about 2000
  lets an honest quote's own minimum fall under it and is refused. That is the
  backstop working: a quote that may deliver under 80% of par is what it
  exists to stop.
- `SettlementLedger` values USDG at `usdc_price`, as it does the other dollar
  stablecoins. It was missing from the set, so every USDG leg or fee was
  unpriced whatever the price source.
- `SettlementLedger`'s `usd_margin` is the sum of per-entry margins: each
  entry's basis net of its own gas, over entries that have both. It was the
  total spread (else the total fee) minus the total gas, which mixed
  populations: an entry whose euro leg was unpriced added its gas but not its
  revenue, and with no priced spread at all the whole basis switched to fees,
  so one EURe entry with a $5 fee read +$4 and adding a $0.000001 USDC spread
  flipped the total to about -$2. A recorded-but-unpriced entry now has no
  basis; only an entry whose legs were never recorded falls back to its fee.
- `min_to_amount` is read the same way by `ExecuteXochiIntent`,
  `ExecuteRelayTransfer` and `ExecuteDepositRoute`, through the new
  `Raxol.Payments.DeliveryFloor`. A value that is not a non-negative integer of
  atomic units (`"1e6"`, `"995000.0"`, `"-1"`, `"abc"`) is refused as
  `{:invalid_min_to_amount, value}`; it used to be read as absent, so a dollar
  destination got no floor at all. On an EURC, EURe or ZCHF destination a floor
  below a tenth of the source amount rescaled to the destination's decimals is
  refused as `{:implausible_min_to_amount, detail}`, which catches a floor
  written in the source's 6 decimals for 18-decimal EURe. A quote is judged on
  the lowest amount it states, its `to_amount` and its own `min_to_amount` when
  it gives one, so a high stated minimum beside a 1-wei estimate does not
  pass. A floor of more than 78 digits is refused rather than parsed.
- `ExecuteDepositRoute` returned a verified Tron deposit address for an EURC,
  EURe or ZCHF destination with no delivery floor, so the payer could fund a
  quote stating any amount. It now takes `min_to_amount`, as
  `ExecuteRelayTransfer` does: a non-USD destination without a positive one is
  refused as `{:unpriced_asset, detail}` before any quote is fetched, and a
  quote stating less than a positive floor, on any destination, returns
  `{:delivery_below_floor, detail}` instead of a deposit address. This filters
  the quote before funding; it does not bound delivery, because the deposit
  attestation does not cover the amount and the floor is not sent to Xochi.
  The deposit instructions from `Protocols.Xochi.deposit_route_quote/3` now
  carry the quote's `min_to_amount`.

- Unknown chains and tokens now fail closed on the Xochi path instead of
  being treated as EVM or 6-decimal. `ExecuteXochiIntent` refuses,
  before quoting, a source or destination token without registered decimals
  (`:route_unsupported`, `{:unknown_asset, _}`; `min_to_amount` does not waive
  it), and routes with chain ids so a Tron
  leg is sent to Relay. `Xochi.Schemas.QuoteRequest.validate/1` refuses stealth
  settlement to any chain outside `Assets.evm_chain_ids/0`, on every quote
  path. `Xochi.Capabilities.vm_type/2` returns `nil` for an unlisted chain, and
  a chain with an unrecognised `vm_type` is dropped (matching is
  case-insensitive). New `Assets.fetch_decimals/2` is the strict lookup.
- Circle USDC on Ethereum, OP, Base and Arbitrum Sepolia is registered for
  decimals and symbol (not as a solver corridor), so testnet Xochi runs keep
  working under the strict lookup.
- An explicit `min_to_amount` on a same-asset Xochi corridor can only raise
  the automatic 80%-of-par delivery floor. It previously replaced it, so
  `min_to_amount: "1"` switched the theft backstop off.
- `EIP712.hash/3` refuses a `uint256` string longer than 78 bytes as
  `{:invalid_uint256, value}` before parsing it. A quote message with a
  5-million-digit amount raised `SystemLimitError` out of the wallet.
- `EIP712` raised `FunctionClauseError` on a value of the wrong Elixir type (a
  float or boolean `uint256`, an integer `bytes32`, a struct that is not a
  map), and read a served `false` as an absent field (encoded as 0). Every
  hash function now returns `{:error, {:invalid_value, type}}` instead. A
  hostile Relay gasless block with such a value, or a wallet that raised,
  exited or threw while signing it, left `ExecuteRelayTransfer`'s reservation
  held; the action now refuses it and releases the reservation.
- A raise inside `Xochi.execute` (on the first execute or the re-quote retry)
  left `ExecuteXochiIntent`'s spend reservation held and its checkpoint in
  place. It is now a definite failure: the reservation is released, the
  checkpoint deleted, and the action returns an error.
- `ExecuteXochiIntent` released its reservation twice when a concurrent run
  of the same payment held the checkpoint key and that record was gone before
  this run read it, handing back one spend's worth of budget. It now releases
  once and returns `:checkpoint_race`, a non-retryable `:rejected` failure.
- `ExecuteDepositRoute` also returns an integral JSON-float `to_amount` or
  `min_to_amount` (`960000.0`) as its integer string; it failed the output
  schema. A fractional float, or one above 2^53 that may not be the integer
  the quote wrote, is refused as `{:invalid_quote_amount, detail}` instead of
  being reformatted.

### Security

- **Breaking.**
  **Every EIP-712 payload a server serves is checked to be exactly the
  canonical typed data before the wallet signs it, and is signed with the
  canonical types, not the served map.** The checks looked at field names
  only, while the encoder hashed whatever root the served `types` map implied,
  so a hostile Xochi quote could add types that made a USDC `Permit` (unlimited
  allowance to the attacker) the struct the wallet signed, or retype the
  ERC-3009 pull's `nonce` to do the same and bypass the solver pin. Now:
  - the Xochi intent must be the v3 `XochiIntent` (typehash checked) with a
    message carrying exactly its fields, under domain name `Xochi`, a version
    whose major is 3, `chainId` = the request's origin chain, `salt` =
    keccak256(version) and no `verifyingContract`
    (`{:intent_mismatch, :intent_type | :intent_fields | {:intent_domain,
    field}}`);
  - an ERC-3009 origin pull must be `ReceiveWithAuthorization` on the
    request's USDC under that chain's USDC domain; a Permit2 pull must be
    `PermitWitnessTransferFrom` + `OriginPullWitness` under name `Permit2`, the
    origin chain and the canonical Permit2 (`{:authorization_mismatch,
    :pull_type | :pull_fields | :pull_token | :pull_chain | :pull_verifier |
    {:pull_domain, field}}`);
  - the Relay gasless block, which was signed unchecked, must be that same
    Permit2 pull for the request's token, chain and amount, with a pinned
    spender (`{:authorization_mismatch, {:gasless, field}}`);
  - x402 signs only for the registered USDC contract on a chain whose USDC
    domain is known (`{:unsupported_asset, _}`), and `network` must be
    `eip155:<chain id>` (`{:invalid_network, _}`);
  - `EIP712.hash/3` refuses a types map with no single root
    (`{:error, :no_primary_type}`) instead of guessing one, and the new
    `EIP712.hash/4` hashes the primary type the caller names.
- **Breaking.**
  **`Req.AutoPay` keeps the spend recorded once a signed payment has left the
  process.** A paid retry answered with a non-2xx status, or lost in
  transport, used to release the reservation, although the server held a
  signed authorization it could still settle; a server answering every paid
  retry with 500 could collect signatures past `session_max` and
  `lifetime_max`. The reservation is now released only when nothing was
  signed: `build_payment/2` returned an error, or a raise, exit or throw
  before signing (a wallet process that crashed or timed out) no longer
  leaks the reservation. An x402 challenge's `validBefore` must be a whole
  second in the future and at most one hour out, the validity AutoPay signs
  when the challenge names none (`{:invalid_valid_before, value}`), so a
  withheld authorization expires within the hour. Its `validAfter` must be a
  non-negative whole second no later than that `validBefore`
  (`{:invalid_valid_after, value}`) and its `nonce` 32 bytes of `0x`-hex
  (`{:invalid_nonce, value}`), so a malformed value is refused before
  anything is reserved or signed. An MPP `methods` field that
  is not a list is refused at parse (`{:invalid_methods, value}`). AutoPay
  passes a challenge refused at parse through as the unpaid 402 and logs the
  refusal's tag; the caller does not see these reasons.
- **Breaking.**
  **`ExecuteRelayTransfer` keeps the spend once a signed gasless pull or a
  deposit broadcast may have left.** A transport error, timeout or 5xx from
  execute after the Permit2 signature was sent released the reservation,
  deleted the checkpoint and reported a retryable network failure, so a retry
  signed a second pull the solver could settle beside the first. Now a
  transport error, timeout, 5xx or raise from execute after a signature, and
  any broadcaster error, raise, exit or throw other than `{:error,
  {:not_sent, reason}}`, keep the reservation (tagged with the `transfer_id`,
  so a refund seen by `PollRelayStatus` releases it) and the checkpoint, and
  return `{:in_doubt, transfer_id}` as a non-retryable `:stranded` failure:
  poll the transfer. A 4xx from execute, or a connection that never opened,
  still releases.
- Error bodies recursively redact both `read_token` and `readToken`; no error
  tuple or replayable Action result carries the bearer secret.
- A read token is never presented to, or deleted under, a different API origin,
  executing principal, or intent id than the execute that issued it.

- x402 and MPP challenges whose atomic amount is wider than a uint256 (more
  than 78 digits, or above 2^256 - 1) are rejected at parse time as
  `{:invalid_amount, _}`. No such amount can be signed. The bound is checked
  before the string is parsed, so a hostile server can no longer make the
  client parse a header-sized number, run a quadratic `Decimal.div` on it, or
  hand `on_confirm` and the telemetry logger a `Decimal` too wide for decimal
  3's 6_178-digit `to_string` limit (which raised, or detached the logger).
- **Breaking.**
  Requires `decimal ~> 3.1 and >= 3.1.2` (was `~> 2.0`) for
  EEF-CVE-2026-32686 (unbounded exponent DoS) and CVE-2026-97853 (below
  3.1.2, `Decimal.round/3` allocates in proportion to its `places`
  argument). Decimal 3 defaults to the decimal128 context: precision 34 (was
  28), `emax: 6_144` / `emin: -6_143` with over/underflow signalled, and
  string parses reject more than 34 digits or an exponent past 6_144. x402
  and `SettlementLedger` convert an atomic amount of up to 78 digits through
  `Assets.to_decimal/1`, and MPP through the integer, so such an amount still
  reaches AutoPay's gates: the required `SpendingPolicy`'s `per_request_max`
  with or without a `:ledger`, and its `session_max` and `lifetime_max` with
  one, compared in the policy's unit.
- **Breaking.**
  Requires `req ~> 0.6 and >= 0.6.1` (was `~> 0.5`) for CVE-2026-49755 and
  CVE-2026-49756, and, when present, `plug ~> 1.19 and >= 1.19.3` (was
  `~> 1.16`) for CVE-2026-54892 and CVE-2026-8468, and `plug_cowboy ~> 2.8 and
  >= 2.8.1` (was `~> 2.7`) for CVE-2026-32688.

## [0.2.1] - 2026-09-09

### Added

- Accounting, fee-schedule, settlement-ledger, and rebalance-policy primitives
  for tracking and managing agent payment rails.
- Runnable agent-payment and privacy-mode examples.

### Changed

- Separated stealth recipient routing from shielded settlement semantics.
- Updated the `raxol_core` and `raxol_agent` requirements to the 2.7 release
  line.

### Fixed

- Bound Xochi quote signatures to the served EIP-712 domain fields.
- Corrected paymaster policy selection and tightened on-chain read boundaries.

### Security

- Bounded and redacted payment telemetry before durable persistence.

## [0.2.0] - 2026-07-11

### Added

- `Raxol.Payments.Mandate`: Xochi delegation envelope. EIP-712-signed
  per-request authorization from a Member to a specific agent wallet.
  Schema mirrors the Mandate typed data the Xochi worker verifies (snake_case
  fields, `string[]` scopes, chainId pinned to 1). Digest verified
  byte-for-byte against viem's `hashTypedData`. Functions:
  `build/1`, `typed_data/1`, `digest/1`, `sign/2`, `verify/1`,
  `to_envelope/1`, `from_envelope/1`, `compute_envelope_hash/1`,
  `expired?/2`, `covers_scope?/2`.
- `Raxol.Payments.Mandate.Store`: singleton ETS + optional DETS
  holder for signed envelopes. Indexed by `envelope_hash` (primary),
  `agent_wallet`, `human_wallet`. Optional persistence via
  `:mandate_store_path` in `Application` config. No consume semantics
  (Xochi enforces budgets server-side).
- `Raxol.Payments.Mandate.Check`: pure selector. Returns the
  soonest-expiring active Mandate that covers a given scope.
- `Raxol.Payments.Req.Mandate`: Req request-step plugin. Attaches
  `X-Xochi-Delegation` header on outbound Xochi-host URLs, mapping
  request path to scope (`/api/intent/quote` → `quote`,
  `/api/intent/execute` → `execute`, `/api/settlement/claim` →
  `stealth_claim`). Passes through unchanged on non-Xochi hosts or
  unrecognized paths.
- Agent Actions for Mandate lifecycle: `payment_create_mandate`,
  `payment_list_mandates`, `payment_revoke_mandate`. Local revoke
  only; Xochi's KV budget counter remains until `expires_at` (no
  server revoke endpoint per Xochi's locked design).
- Registered the `payment_execute_relay_transfer` and
  `payment_poll_relay_status` Actions in the default set
  (`Raxol.Payments.Actions.Payments.actions/0`); the Tron relay rail
  modules existed but were not aggregated.

### Changed

- Renamed the `payment_get_balance` Action to `payment_get_wallet_info`
  (module `GetBalance` → `GetWalletInfo`). It returns the wallet address
  and chain ID, not an on-chain balance, so the old name was misleading.

## [0.1.0]

Initial release. Autonomous agent payment capabilities.

### Added

- `Raxol.Payments.Protocol`: behaviour for payment protocol
  detection + signing. Impls: `X402`, `MPP`, `Xochi`, `Riddler`.
- `Raxol.Payments.Wallet`: behaviour for key management. Impls:
  `Wallets.Env` (env var), `Wallets.Op` (1Password via GenServer).
- `Raxol.Payments.EIP712`: typed-data hashing for scalar types
  (address, uint256, bytes32, string, bool). Used by wallet impls and
  ACP memo signing.
- `Raxol.Payments.Req.AutoPay`: Req response-step plugin that
  handles HTTP 402 transparently. Detects protocol, checks spending
  budget, signs payment, retries.
- `Raxol.Payments.Router`: routes between protocols based on chain,
  privacy preference, and trust score. Same-chain 402 → x402/MPP;
  cross-chain → Xochi; privacy → Xochi.
- `Raxol.Payments.SpendingPolicy`: per-request/session/lifetime
  spending limits + domain allowlist + confirmation thresholds.
- `Raxol.Payments.Ledger`: ETS-backed spend tracking GenServer.
  Atomic `try_spend/5` prevents TOCTOU races. Sliding-window session
  budgets.
- `Raxol.Payments.SpendingHook`: CommandHook impl that gates
  payment commands against `SpendingPolicy` + `Ledger`.
- Agent Actions: `payment_get_balance`, `payment_get_quote`,
  `payment_transfer`, `payment_spending_status`,
  `payment_list_history`.
- `Raxol.Payments.Xochi.Stealth`: ERC-5564 / ERC-6538 stealth
  addresses (secp256k1, view tag scanning, domain-separated key
  derivation, meta-address encode/decode).
- `Raxol.Payments.Pxe.Client`: JSON-RPC 2.0 client for the Aztec
  Private eXecution Environment (shielded settlement).
- `Raxol.Payments.PrivacyTier`: Glass Cube model, 6 attestation-
  gated privacy tiers.
- `Raxol.Payments.Zksar`: ZKSAR attestation proof verification (6
  proof types) and `Zksar.TrustScore` (diminishing-returns
  aggregation).

# Composing Peer and Xochi legs

`Raxol.Payments.Ramp.Composition` coordinates the existing `Ramps` and Xochi
execute/poll APIs. The host supplies a trusted plan, a principal-scoped durable
checkpoint store, and independent `peer_context`, `peer_approval`, and
`xochi_context` maps. Never put Peer credentials, identity, payment handles,
proof/session material, provider order handles or raw responses in these maps.

Call `Composition.create(id, plan, context)` with these plan fields:

- `direction`: `"onramp"` or `"offramp"`.
- `peer_operation`: widget-minted public operation reference.
- `recipient`: connected wallet address and Peer intent recipient.
- `atomic`, `decimals`: canonical positive atomic string and registered source
  decimals for the independent Xochi route.
- `peer_atomic`: Base USDC amount from the Peer preview (`receive` for onramp,
  `pay` for offramp).
- `route`: existing Xochi parameters `from_chain_id`, `to_chain_id`, `from_token`,
  `to_token`, `settlement`, and optional `recipient_address`,
  `recipient_meta_address`, `min_to_amount`, `slippage_bps`.

The Peer context contains the single-leg `Ramp.Preview` and `Ramp.Intent`,
spending policy and trusted runtime dependencies. The Xochi context contains its
wallet, configuration, policy, ledger, principal and confirmation callback. A
strict allowlist selects Xochi dependencies; Peer context is never merged in.
Atomic values are converted exactly with Decimal for the existing action's
human-decimal input. Signing, quote binding, spending limits, delivery floors,
and read-token ownership remain enforced by the existing actions.

Call `Composition.advance(id, leg, action, context)` with `:peer` or `:xochi`
and `:approve`, `:resume`, or `:status`. Each first dispatch requires separate
explicit consent. Xochi confirmation receives the exact source amount and
`"xochi"`; the host must show the stored route terms with that prompt. Its
spending policy independently prices and authorizes the spend. Peer resume
uses its existing action reference and revision command in `peer_context`.

Onramp routing cannot even quote until Peer is completed and its payout released.
The route cannot spend more than the preview's confirmed Base USDC amount.
Offramp routes must deliver public canonical Base USDC to the same wallet, with
a minimum covering the Peer deposit. Peer starts only after an owner-view poll
confirms public settlement on Base; a completion label alone is insufficient.

`Composition.status/2` reads without dispatching. Overall state is derived from
leg states and never stored. Independent references and sanitized receipts are
retained. Completed legs cannot be executed again; the following leg always
requires another call and approval.

An in-doubt Xochi leg only polls its original intent, recovering a lost public
reference from its existing dispatch checkpoint if necessary. A clean execute
failure with no dispatch checkpoint, confirmed refund, or confirmed expiry
allows a new `:approve`, with a new attempt key, fresh quote and separate consent.
Previous attempts remain in `xochi_history`. Ambiguous failures stay in doubt.
Peer resume delegates to its existing recovery API without repeating Xochi.
After confirmed terminal Peer failure, obtain a fresh preview/public reference
for the same amount and wallet, update `peer_context` and `peer_approval`, call
`Composition.retry_peer(id, new_operation, context)`, then separately approve
that Peer leg. The prerequisite and previous `peer_history` receipts remain.

Keep original preview/intent terms available for recovery. Missing dispatch
evidence remains conservatively in doubt and requires operator reconciliation;
checkpoint expiry does not prove non-submission. Production requires durable
principal-scoped stores and shared locks across nodes. ETS unit tests protect
process interruption only. No live mainnet payment is part of the unit suite.

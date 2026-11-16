# Peer maker runtime

`Peer` now ships concrete offramp discovery, preview, unsigned planning, wallet
approval and reconciliation implementations. The injectable `MakerIO`,
`MakerWallet` and `ChainReader` behaviours remain available for offline tests.
No approved-key maker API, fiat credential, OAuth session or private key is used
by the default integration.

Start `Peer.Runtime` under the application's supervisor with `mapping_path:`
(a dedicated private directory) and a fixed `mapping_name:` DETS atom. Attach
its children with `Peer.Runtime.context(runtime, payment_context)`. Starting
these resources performs no network or wallet action.

The existing payment context must supply:

- `user`: the authenticated wallet's public address, with operation refs scoped
  to that wallet by the host.
- `checkpoint`: an existing Checkpoint implementation durable across the failure
  boundary being protected. The in-memory ETS backend protects caller crashes;
  deployments needing VM-restart recovery must configure durable checkpoints.
- `peer_cashout_policy`, `ledger` and `agent_id`: a dedicated Peer policy and the
  existing atomic spending ledger. Reservations use the separate ledger account
  `{:peer_cashout, agent_id}`. Generic Xochi spending under `agent_id` neither
  consumes nor replenishes this class; a generic `policy` does not authorize
  cash-out. Withdrawals conservatively reserve their reviewed amount too.
- `wallet`: an existing `Raxol.Payments.Wallet` module providing `address/0`,
  `chain_id/0`, `sign_hash/1`; this may be an external/hardware signer. This code
  never fetches or stores its private key.
- `on_confirm`: the existing explicit human approval callback. It is consulted
  for every wallet action regardless of the spending threshold.
- `maker_registrations`: provider-private runtime setup attestations keyed by
  rail, containing public `wallet`, `payee_hash` and `own_account_verified: true`.
  These must originate in trusted user-owned account setup, never model/action
  input. No payment handle or credential enters Raxol. This attestation is not
  persisted. Identity/Autopilot-gated rails remain setup-required because public
  data does not establish their readiness.

Optional `chain_reader` overrides the concrete existing JSONRPC reader (default:
Base public RPC). `maker_rails` narrows the queried rails; a catalog entry alone
never enables a rail. `maker_max_fee_per_gas` bounds transaction gas price
(default 100 gwei); the wallet also refuses gas estimates above two million.

## Public reads and estimates

The public Peer indexer supplies live payment-method/currency template and order
observations. EscrowV2 and OrchestratorV4 paused state, Base USDC balance, intent
ranges, active currency/method, effective rate and inline oracle configuration
are read at one pinned Base block. `getEffectiveRate` must succeed; stale oracle
reverts do not become estimates. Block timestamp freshness is bounded to 30
seconds. Bounds are narrowed to the template's intent range and current wallet
balance. Estimates round proceeds down/required USDC up and disclose approximate,
asynchronous partial-fill semantics. They are not guaranteed prices or ETAs.

The shared indexer process honors both numeric and HTTP-date Retry-After on
429, blocks subsequent HTTP requests until the deadline and never sleeps or
retries automatically. HTTP, GraphQL, missing-data, oversized-response and chain
failures return bounded codes, availability_unknown or in_doubt.

## Approval and recovery

Pass the returned validated preview and intent in trusted context to
`Peer.approve(operation, quote, command, context)`. Commands require
`approved: true`, `expected_revision: "0"` and a unique `idempotency_key`.
Unsigned plans are recomputed from fresh protocol terms and independently
validated by the default wallet boundary before SpendGate reserves budget.
Every signature uses the existing `wallet.sign_hash/1` path after explicit human
confirmation. Only exact bounded USDC allowance is allowed.

Insufficient allowance produces a separate `approve_usdc` transaction. After its
finalized receipt, status exposes `action_required`; `recover_peer` with the
current revision, a new idempotency key and explicit approval prepares the
original deposit. If the old preview expired while approval finalized, request
a fresh preview using `resume_operation_ref: original_operation` in trusted
context and explicitly review that new quote. This reuse is allowed only after
confirmed allowance approval and before any deposit submission. It never
recreates an already submitted deposit.

The wallet reserves a nonce and durably saves the signed transaction's hash and
expected calldata digest before broadcasting once. It never persists calldata,
signatures or signed transactions. Unknown submission outcome permits only
status reconciliation. Pending action refs must match; transaction sender,
chain, target, input digest, value, successful receipt and finalized block must
agree. Creation extracts the deposit ID only from one matching DepositReceived
escrow event. A pending withdrawal cannot resolve from an older deposit receipt.

Order reads compare the indexer with EscrowV2 deposit balances and active hashes,
OrchestratorV4 intent amounts and ProtocolViewerV4 available liquidity. Verified
fill and withdrawal totals must agree with indexer totals and the stored original
amount; pending fiat never counts as a fill. Unknown/stale/inconsistent evidence
stays in doubt. Withdrawal (`recover_peer` plus atomic `amount`, new key, current
revision and `approved: true`) cannot exceed fresh unmatched liquidity or fully
close a deposit with active intents.

The public checkpoint retains only operation ref, revision, idempotency key,
sanitized snapshot and public pending-action ref. The separate private DETS
mapping retains protocol IDs, atomic total, public transaction hashes/digests,
owner binding and nonce claims. Uncertain handoffs retain spending reservations;
there is no automatic refund or rebroadcast. The Xochi signed Mandate's existing
scopes remain quote/execute/stealth_claim; automatic Peer delegation would need
an explicitly agreed Peer mandate scope rather than reusing a Xochi envelope.

## Cross-runtime evidence

`test/fixtures/ramp/peer_maker_calldata.json` contains only synthetic unsigned
vectors generated by S5 `createSDKMakerIO` using the real pinned
`@zkp2p/sdk@0.15.0-rc.11`: exact approvals, two deposits, partial/full withdrawal,
and viem's unsigned EIP-1559 serialization/digest. Tests compare every calldata
byte, including SDK attribution suffixes. The reproducible generator accepts
paths to the S5 adapter and pinned SDK module and runs through `tsx`; it invokes
no wallet, RPC or API. Contract ABIs/deployments are pinned from that same SDK in
`priv/ramp/peer_contracts.json`; they supply encoding metadata, never capability
authority.

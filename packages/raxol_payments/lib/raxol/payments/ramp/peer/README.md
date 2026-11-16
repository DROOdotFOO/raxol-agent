# Maker runtime integration

`Peer.approve/4`, `status/2` and `recover/4` delegate to `Peer.Maker`.
These callbacks fail closed unless the trusted host supplies:

- `checkpoint`: an existing `Raxol.Payments.Checkpoint` store that survives its
  caller (a durable implementation is required across VM restarts).
- `maker_mapping`: a supervised `Peer.Mapping` process, with a fixed DETS name
  and a dedicated private path; never share that path with public checkpoints.
- `maker_io` and `maker_wallet`: `{module, handle}` implementations of the
  `MakerIO` and `MakerWallet` behaviours. The host must scope both to the same
  authenticated wallet and scope operation refs to that wallet.
- `policy` and `ledger`: the existing spending policy and atomic ledger.
- `preview` and `intent`: validated, fresh maker terms for initial approval.

The R1 buyer quote transport cannot establish maker pricing or seller readiness.
It continues to refuse offramp discovery. A trusted maker adapter must obtain a
fresh maker preview and revalidate it when preparing the plan; there is no live
maker network or wallet adapter enabled by this change.

Initial commands require `approved: true`, `expected_revision: "0"` and a
nonempty `idempotency_key`. The returned `requires_user` action contains only an
opaque public action ref and the named wallet action. Each signature and
transaction must be reviewed by the user through the wallet implementation.
The wallet validates exact plan economics and recipients independently before
`SpendGate` reserves policy budget. Mandates authorize Xochi API calls and do not
replace wallet approval for Peer transactions.

After handoff the snapshot is `in_doubt` and advertises only `check_status`.
The wallet records the pending public action ref inside the trusted maker
runtime before requesting a signature. Reconciliation must resolve that exact
handoff, including a pending withdrawal; an existing deposit receipt cannot
resolve a new withdrawal. Without conclusive evidence, return pending forever
rather than preparing another transaction. Mapping reconstruction uses existing
protocol operations and never creates a deposit.

A confirmed open deposit may advertise `recover_peer`. This requests a distinct
withdrawal approval with `amount` (atomic Base USDC), a new `idempotency_key`,
`approved: true` and the current `expected_revision`. The amount cannot exceed
fresh unmatched funds. Reserved fees and active intents must be excluded by the
protocol adapter. Withdrawals pass the same spending gate conservatively; a lost
wallet response retains its reservation. There is deliberately no automatic
budget refund or transaction retry after uncertainty.

The checkpoint contains only operation ref, revision, idempotency key, sanitized
snapshot and public pending-action ref. The separate mapping contains deposit
and order IDs and total atomic amount. Never persist unsigned plans, payees,
proofs, signatures, raw errors or provider responses. Wallet rejection or
preparation failure conservatively leaves the operation status-only; obtaining
conclusive protocol evidence is required to leave that state.

# Raxol Payments

Payment rails for Raxol agents: x402 and MPP auto-pay, Permit2, Xochi cross-chain intents,
stealth addresses, ZKSAR attestations, Xochi Mandate delegation, and per-request, session and
lifetime spending limits. The design is in
[Agentic Commerce](https://github.com/DROOdotFOO/raxol-agent/blob/main/docs/features/AGENTIC_COMMERCE.md).

## Install

```elixir
{:raxol_payments, "~> 0.4"}
```

0.3 requires `raxol_agent` 3.0 and `raxol_core` 2.8.

## Quick start

```elixir
alias Raxol.Payments.{Router, SpendingPolicy, Req.AgentPlugin}

Router.select(cross_chain: true)  # => :xochi
Router.select(privacy: :stealth)  # => :xochi
Router.select()                   # => :x402

# A SpendingPolicy is required.
plugin = AgentPlugin.auto_pay(
  wallet: Raxol.Payments.Wallets.Env,
  ledger: ledger_pid,
  policy: SpendingPolicy.dev(),
  agent_id: :my_agent
)
```

## Modules

- `Protocol` with `Protocols.{X402, MPP, Xochi, Permit2}`: detection and signing.
- `Wallet` with `Wallets.Env` (refuses to load in production without opt-in) and `Wallets.Op`
  (1Password).
- `Router`: protocol selection from chain, privacy and trust score.
- `SpendingPolicy`, `Ledger`, `Actions.SpendGate`: atomic, fail-closed spending limits.
- `Zksar`, `Zksar.TrustScore`, `PrivacyTier`: attestation verification and the tier it unlocks.
- `Xochi.Stealth`: ERC-5564/6538 stealth addresses.
- `Mandate`, `Mandate.Store`, `Req.Mandate`: Xochi delegation envelopes.
- `Pxe.Client`: Aztec PXE JSON-RPC client.
- `Checkpoint.{ETS, ContextStore}`: crash recovery for cross-chain dispatch.

## Relay (Tron) funding

`Actions.Payments.ExecuteRelayTransfer` funds an EVM-to-Tron transfer in one of three ways:

- gasless: a signed Permit2 `gasless` block that the solver pulls. The solver serves it only with
  `RELAY_GASLESS_PULL_ENABLED=true`.
- broadcast: an on-chain transfer to `deposit_address` by the `:broadcaster` in context.
- external: the deposit address is returned for another wallet to fund.

## Examples

[`examples/`](https://github.com/DROOdotFOO/raxol-agent/blob/main/packages/raxol_payments/examples/README.md)
runs from `preflight.exs` (local echo server, no funds) to
`crosschain_stealth_payment.exs` (in-process Xochi simulation, no funds) to
`scripts/run_live_gates.sh` at the repository root (live settlement with real funds).

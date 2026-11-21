# raxol_earn

An Elixir/OTP seller for the [Virtuals](https://app.virtuals.io) Agent Commerce Protocol (ACP).
`raxol_payments` covers paying; `raxol_earn` covers being paid. Pre-alpha. It runs the v2
hook/event model (`JobSession` + `HookClient` -> `AgenticCommerceV3`) on Base. See
`MIGRATION_V2.md` for the retired v1 memo model.

This ACP is unrelated to the editor Agent Client Protocol in `raxol_agent_client_protocol`.

## Install

```elixir
{:raxol_earn, "~> 0.2"}
```

The OTP application starts `Raxol.Earn.Supervisor`.

## Job sessions

Each active job runs in one supervised `Raxol.Earn.JobSession`, registered by
`{chain_id, job_id}`:

```
:open -> :budget_set -> :funded -> :submitted -> :completed
                                            \-> :rejected
(any non-terminal) -> :expired
```

`JobSession.Status` holds the transition graph as pure functions. A session emits
`[:raxol, :earn, :job_session, :transition]` on every change and stops when it reaches a terminal
status. `apply_event/3` applies a status observed on-chain or over SSE.

`JobSession.Provider` drives the seller side. It calls the offering handler, writes the hook call
on-chain (the commit point: a failed write leaves the session unchanged), then mirrors the
status. It writes the encoded deliverable to a `Raxol.Payments.Checkpoint` before signing, and
`Raxol.Earn.Seller.Resync` re-drives interrupted jobs on boot or reconnect, so a restart resumes a
job instead of submitting twice. Production should set `require_checkpoint: true`.

## Offerings

```elixir
defmodule MyOffering do
  use Raxol.Earn.Offering,
    name: "sentiment_analysis",
    price_usdc: 10,
    sla_minutes: 5,
    cluster: "analytics"

  @impl true
  def handle_request(request, _ctx), do: {:accept, %{quoted_usdc: 10, text: request.text}}

  @impl true
  def handle_deliver(request, _ctx), do: {:deliver, %{sentiment: analyze(request.text)}}
end
```

`config :raxol_earn, :offerings` lists what the seller registers. The default is only
`Raxol.Earn.Xochi.UsdcPublicOffering` (`xochi_usdc_public`), because it is the only rail that
settles today. Others must be added explicitly:

- `Xochi.StablePublicOffering`, `Xochi.StableStealthOffering`: token-agnostic cross-chain
  stablecoin transfers (stealth settles to Ethereum L1 only).
- `Xochi.TransferOffering`: deprecated, kept so existing `xochi_cross_chain_transfer` jobs
  settle.
- `Console.AgentOffering` (`custom_console_agent`): sells a validated Virtuals Console agent
  package. Config is in `config/console_offering.example.exs`, and the go-live steps are in
  `RUNBOOK.md`.

The Xochi offerings are pure storefronts. The buyer quotes and signs a Xochi intent
(`Raxol.Payments.Protocols.Xochi.quote_and_sign/3`). `Xochi.Settler` relays it with
`execute_signed/2` without re-signing, and the ACP budget is only the storefront fee. See
`examples/buyer_signed_intent.exs`.

### Liquidity gate

`handle_request/2` accepts only corridors it can settle now, so a buyer is rejected before escrow.
The checks are config-driven and inert by default:

- the live `Raxol.Payments.Xochi.Capabilities` matrix, falling back to `Raxol.Payments.Assets`;
- per-order caps (`:destination_caps`; `0` closes a corridor);
- closed origins (`:closed_origins`);
- a rolling aggregate reservation (`Xochi.CapacityLedger`), enabled with
  `capacity_gate_enabled: true`.

`mix raxol_earn.derive_caps` derives the caps from the solver's on-chain balances, and
`Xochi.CapacityRefresher` refreshes them. Start from `config/destination_caps.example.exs`.

## On-chain writes

`Raxol.Earn.HookClient` (`set_budget`, `submit`, `complete`, `reject`) writes through an injected
`Raxol.Earn.ProviderAdapter`:

- `SCA`: sponsored ERC-4337 v0.7 UserOps (`Raxol.Earn.Wallet.SCA`, Alchemy Modular Account v2). It
  deploys the account on its first write.
- `JSONRPC`: an EOA signing EIP-1559 transactions. Nonces are serialized by
  `Raxol.Earn.Wallet.NonceServer`, which resyncs after a send that fails before broadcast.
- `Privy`: a Virtuals-managed Privy wallet, signed by a local Node sidecar.
- `Mock`: in process, for tests and `mix raxol_earn.bench`.

ABIs are vendored in `priv/abi/`. Verified Base addresses are in `Raxol.Earn.Chain`.

## Seller runtime

Enable it with `:seller_enabled`. `Seller.Supervisor` runs `Seller.Queue` (a bounded mailbox) and
`Seller.Runtime` over a backend: `Backend.InMemory` (the default) or `Backend.WebSocket`
(Socket.IO v4 over `Mint.WebSocket` to the Virtuals relayer).

## License

MIT. See `LICENSE.md`.

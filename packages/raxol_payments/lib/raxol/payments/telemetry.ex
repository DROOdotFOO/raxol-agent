defmodule Raxol.Payments.Telemetry do
  @moduledoc """
  Telemetry event surface for the payment subsystem.

  Every event is emitted via `:telemetry.execute/3`; attach a handler from your
  application's start-up code to forward it anywhere.

  `events/0` lists every event, each classified as `:invariant`, `:peer` or
  `:operational`. `:invariant` events (ones that can only fire if this library
  is wrong) are armed by `Raxol.Core.Telemetry.InvariantSentinel`, which fails
  any test in which they fire. This package declares none: every alarming
  event here resolves to the solver, the chain, the network, the clock or a
  deployment choice. The registry makes each new event be classified before it
  ships.

  ## Events

  | Event | Measurements | Metadata |
  | ----- | ------------ | -------- |
  | `[:raxol, :payments, :spend]` | `:amount` (`Decimal`, human units) | `:agent_id`, `:currency`, `:metadata` |
  | `[:raxol, :payments, :over_budget]` | `:amount` | `:agent_id`, `:limit_type` (`:per_request` \\| `:session` \\| `:lifetime` \\| `:frozen`) |
  | `[:raxol, :payments, :freeze]` | | `:frozen?` |
  | `[:raxol, :payments, :xochi, :settled]` | `:elapsed_ms` | `:intent_id`, chains, tokens, amounts, `:xochi_fee`, `:tx_hash`, `:settlement_type` |
  | `[:raxol, :payments, :settlement]` | `:fee_atomic`, `:gas_wei` (nil when unknown) | `:intent_id`, chains, `:token_symbol`, gas chain/symbol/status, `:settlement_type` |
  | `[:raxol, :payments, :margin]` | `SettlementLedger.report/2` totals | `:corridor_count` |
  | `[:raxol, :payments, :rebalance, :recommendation]` | `:amount` | `:type` (`:refuel_gas` \\| `:rebalance_usdc` \\| `:alert`) and type-specific keys |
  | `[:raxol, :payments, :rebalance, :advice]` | `:count` | `:refuel_count`, `:rebalance_count`, `:alert_count` |

  `:spend` fires when `Raxol.Payments.Ledger` records a spend, `:over_budget`
  when a policy cap or the freeze denies one, `:freeze` on a freeze toggle.
  `:xochi, :settled` fires from `Protocols.Xochi.transfer/4` on a completed
  intent and feeds `Raxol.Payments.SettlementAccountant`; `:settlement` fires
  once per intent `SettlementLedger` books. `:margin` fires once per
  `RebalanceMonitor` sweep; each `usd_*` total is over its own population (see
  `SettlementLedger`'s `aggregate` type), and `RebalanceMonitor.margin_report/1`
  has the per-corridor detail. The remaining events are documented at their
  emit sites.

  ## Attaching a handler

      :telemetry.attach_many(
        "my-pay-watcher",
        [
          [:raxol, :payments, :spend],
          [:raxol, :payments, :over_budget],
          [:raxol, :payments, :freeze]
        ],
        &MyApp.PayWatcher.handle/4,
        nil
      )
  """

  # Each verdict is read off the emit site, not the event name.
  use Raxol.Core.Telemetry.Invariants,
    events: %{
      [:raxol, :payments, :spend] => :operational,
      # A caller-supplied policy cap or freeze: the gate working.
      [:raxol, :payments, :over_budget] => :operational,
      [:raxol, :payments, :freeze] => :operational,
      # The solver refunded; the ledger reconciles idempotently by reservation tag.
      [:raxol, :payments, :refund_reconciled] => :operational,
      [:raxol, :payments, :settlement] => :operational,
      # A negative margin is a fact about the corridors, not a defect here.
      [:raxol, :payments, :margin] => :operational,
      # An `:alert` is a fact about an underfunded wallet, not a defect here.
      [:raxol, :payments, :rebalance, :recommendation] => :operational,
      [:raxol, :payments, :rebalance, :advice] => :operational,
      [:raxol, :payments, :xochi, :settled] => :operational,
      [:raxol, :payments, :xochi, :agent_stream, :announced] => :operational,
      # The endpoint refused (429, non-202) or the network failed; announces
      # are best-effort and never affect the swap.
      [:raxol, :payments, :xochi, :agent_stream, :dropped] => :peer,
      # No announce attempted: unconfigured topic/wallet/host, mandate binding,
      # or an expired route stash.
      [:raxol, :payments, :xochi, :agent_stream, :announce_skipped] => :operational,
      # `PollXochiStatus` timed out before a terminal status: the solver or
      # chain is slow or refusing, and the operator gets the intent id.
      [:raxol, :payments, :xochi, :intent_stranded] => :peer,
      # No checkpoint store while not required: a deployment choice, and the
      # happy path of every settlement test without one.
      [:raxol, :payments, :xochi, :unchecked_settlement] => :operational
    }
end

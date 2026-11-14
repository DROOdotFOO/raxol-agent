defmodule Raxol.Payments.Actions.Payments.Transfer do
  @moduledoc """
  Agent Action that AUTHORIZES an explicit same-chain transfer to an address.

  This is a governance checkpoint, not an executor. It runs the spend through
  `Raxol.Payments.Actions.SpendGate` (approved-address confirmation threshold +
  atomic ledger reservation) and returns an `"authorized"` status. It does NOT
  itself broadcast a transaction: this package has no same-chain EOA send rail.
  Cross-chain and stealth transfers execute through
  `Raxol.Payments.Actions.Payments.ExecuteXochiIntent`; a same-chain send is
  performed by the caller's own rail after this authorization.

  `amount` is a human amount of `currency` (a ticker, default `"USDC"`).
  `SpendGate` converts it into the spending policy's unit
  (`Raxol.Payments.SpendPricing`: a stablecoin pegged to it at par, a token
  that is not a stablecoin at its USD price from the configured source under
  a USD policy, a stablecoin pegged to another currency refused) or refuses it as
  `{:unpriced_asset, detail}`; `reserved` is the converted amount the ledger
  holds. If an authorized transfer is abandoned, release `reserved` with
  `SpendGate.release/3` so the budget is not permanently consumed.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_transfer",
    sensitive: true,
    description:
      "Authorize an explicit same-chain transfer to an address: runs the spend gate and reserves budget, but does NOT broadcast. Use payment_execute_xochi_intent to actually move funds cross-chain or with privacy.",
    schema: [
      input: [
        to: [
          type: :string,
          required: true,
          description: "Recipient address (0x...)"
        ],
        amount: [type: :string, required: true, description: "Amount to send"],
        currency: [type: :string, description: "Currency (default: USDC)"]
      ],
      output: [
        status: [type: :string],
        from: [type: :string],
        to: [type: :string],
        amount: [type: :string],
        reserved: [type: :string]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(%{to: to, amount: amount_str} = params, context) do
    case Map.fetch(context, :wallet) do
      {:ok, wallet} ->
        do_transfer(wallet, to, amount_str, params, context)

      :error ->
        {:error, :missing_wallet}
    end
  end

  defp do_transfer(wallet, to, amount_str, params, context) do
    currency = Map.get(params, :currency, "USDC")
    amount = Decimal.new(amount_str)

    with {:ok, reserved} <-
           SpendGate.authorize(context, amount,
             asset: {:symbol, currency},
             target: {:address, to},
             metadata: %{to: to, type: :explicit_transfer}
           ) do
      # "authorized", not "pending": the spend gate passed and budget is
      # reserved, but this action does not broadcast, so nothing is in flight.
      {:ok,
       %{
         status: "authorized",
         from: wallet.address(),
         to: to,
         amount: amount_str,
         reserved: Decimal.to_string(reserved)
       }}
    end
  end
end

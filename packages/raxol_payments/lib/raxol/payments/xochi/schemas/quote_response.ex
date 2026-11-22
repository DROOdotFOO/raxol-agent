defmodule Raxol.Payments.Xochi.Schemas.QuoteResponse do
  @moduledoc """
  A Xochi quote: the intent and quote ids to sign and execute, the delivered
  amount and fee, and the EIP-712 data or pull authorization the wallet signs.
  `can_solve` is false when no solver can fill the request.
  """
  import Raxol.Payments.Xochi.Schemas, only: [pick: 2]

  @enforce_keys [:intent_id, :quote_id]
  defstruct [
    :intent_id,
    :quote_id,
    :to_amount,
    :min_to_amount,
    :xochi_fee,
    :xochi_fee_rate,
    :estimated_gas_cost,
    :expiry,
    :eip712_data,
    :pull_authorization,
    :deposit_address,
    :deposit_attestation,
    :deposit_deadline,
    :payment_method,
    :error,
    can_solve: false,
    gasless: false,
    gasless_fee: nil,
    settlement_options: []
  ]

  @type t :: %__MODULE__{
          intent_id: String.t(),
          quote_id: String.t(),
          can_solve: boolean(),
          to_amount: String.t() | nil,
          min_to_amount: String.t() | nil,
          xochi_fee: String.t() | nil,
          xochi_fee_rate: String.t() | nil,
          estimated_gas_cost: String.t() | nil,
          expiry: term() | nil,
          gasless: boolean(),
          gasless_fee: String.t() | nil,
          eip712_data: map() | nil,
          pull_authorization: map() | nil,
          deposit_address: String.t() | nil,
          deposit_attestation: String.t() | nil,
          deposit_deadline: integer() | nil,
          payment_method: String.t() | nil,
          settlement_options: [map()],
          error: String.t() | nil
        }

  @doc """
  A deposit-route quote: a non-EVM (Tron/Solana) origin with no gasless pull,
  so the quote carries a `deposit_address` the payer sends funds to (verify the
  `deposit_attestation` first) instead of EIP-712 typed data to sign.
  """
  @spec deposit_route?(t()) :: boolean()
  def deposit_route?(%__MODULE__{deposit_address: a}) when is_binary(a) and a != "", do: true
  def deposit_route?(_), do: false

  # The worker answers snake_case with `eip712`; simulators answer camelCase
  # with `eip712Data`. Both are read.
  @spec from_json(map()) :: t()
  def from_json(json) do
    %__MODULE__{
      intent_id: pick(json, ["intent_id", "intentId"]),
      quote_id: pick(json, ["quote_id", "quoteId"]),
      can_solve: pick(json, ["can_solve", "canSolve"]) || false,
      to_amount: pick(json, ["to_amount", "toAmount"]),
      min_to_amount: pick(json, ["min_to_amount", "minToAmount"]),
      xochi_fee: pick(json, ["xochi_fee", "xochiFee"]) || get_in(json, ["fee", "fee_amount"]),
      xochi_fee_rate: pick(json, ["xochi_fee_rate", "xochiFeeRate"]),
      estimated_gas_cost:
        pick(json, ["estimated_gas_cost", "estimatedGasCost", "estimated_gas_cost_usd"]),
      expiry: pick(json, ["expiry", "expires_at"]),
      gasless: pick(json, ["gasless"]) || false,
      gasless_fee: pick(json, ["gasless_fee", "gaslessFee"]),
      eip712_data: pick(json, ["eip712", "eip712Data"]),
      pull_authorization: pick(json, ["pull_authorization", "pullAuthorization"]),
      deposit_address: pick(json, ["deposit_address", "depositAddress"]),
      deposit_attestation: pick(json, ["deposit_attestation", "depositAttestation"]),
      deposit_deadline: pick(json, ["deposit_deadline", "depositDeadline"]),
      payment_method: pick(json, ["payment_method", "paymentMethod"]),
      settlement_options: pick(json, ["settlement_options", "settlementOptions"]) || [],
      error: pick(json, ["error", "reason"])
    }
  end
end

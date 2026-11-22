defmodule Raxol.Payments.Xochi.Schemas.Intent do
  @moduledoc """
  A persisted Xochi intent as returned by `GET /api/intent/:id`.

  Unlike `IntentStatus` (settlement/tx state only), this carries the
  authoritative corridor and amounts written at quote time (`status: :quoted`),
  so a relayer can read what the buyer signed before settlement. Amounts are
  token base-unit strings; `fee_rate` is the tier fraction (e.g. `0.003`).
  """

  import Raxol.Payments.Xochi.Schemas, only: [pick: 2]

  alias Raxol.Payments.Xochi.Schemas.Status

  @enforce_keys [:intent_id, :status]
  defstruct [
    :intent_id,
    :status,
    :from_chain_id,
    :to_chain_id,
    :from_token,
    :to_token,
    :from_amount,
    :to_amount,
    :quote_id,
    :tier,
    :fee_rate,
    :settlement_type
  ]

  @type t :: %__MODULE__{
          intent_id: String.t(),
          status: Status.t(),
          from_chain_id: pos_integer() | nil,
          to_chain_id: pos_integer() | nil,
          from_token: String.t() | nil,
          to_token: String.t() | nil,
          from_amount: String.t() | nil,
          to_amount: String.t() | nil,
          quote_id: String.t() | nil,
          tier: String.t() | nil,
          fee_rate: number() | nil,
          settlement_type: String.t() | nil
        }

  @spec from_json(map()) :: t()
  def from_json(json) do
    %__MODULE__{
      intent_id: pick(json, ["intent_id", "intentId", "id"]),
      status: Status.parse(json["status"]),
      from_chain_id: pick(json, ["from_chain_id", "fromChainId"]),
      to_chain_id: pick(json, ["to_chain_id", "toChainId"]),
      from_token: pick(json, ["from_token", "fromToken"]),
      to_token: pick(json, ["to_token", "toToken"]),
      from_amount: pick(json, ["from_amount", "fromAmount"]),
      to_amount: pick(json, ["to_amount", "toAmount"]),
      quote_id: pick(json, ["quote_id", "quoteId"]),
      tier: json["tier"],
      fee_rate: pick(json, ["fee_rate", "feeRate"]),
      settlement_type: pick(json, ["settlement_type", "settlementType"])
    }
  end
end

defmodule Raxol.Payments.Xochi.Schemas.ExecuteRequest do
  @moduledoc """
  The signed intent sent to `POST /api/intent/execute`.
  """
  alias Raxol.Payments.Xochi.Schemas

  @enforce_keys [:intent_id, :quote_id, :signature, :nonce]
  defstruct [
    :intent_id,
    :quote_id,
    :signature,
    :nonce,
    :deadline,
    :pull_signature,
    :aztec_proof
  ]

  @type t :: %__MODULE__{
          intent_id: String.t(),
          quote_id: String.t(),
          signature: String.t(),
          nonce: non_neg_integer(),
          deadline: integer() | nil,
          pull_signature: String.t() | nil,
          aztec_proof: String.t() | nil
        }

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = req) do
    base = %{
      "intent_id" => req.intent_id,
      "quote_id" => req.quote_id,
      "signature" => req.signature,
      "nonce" => req.nonce
    }

    base
    |> Schemas.put_non_nil("pull_signature", req.pull_signature)
    |> Schemas.put_non_nil("aztec_proof", req.aztec_proof)
  end
end

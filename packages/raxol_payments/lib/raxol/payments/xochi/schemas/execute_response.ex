defmodule Raxol.Payments.Xochi.Schemas.ExecuteResponse do
  @moduledoc """
  The answer to `POST /api/intent/execute`. `reconciling` is true when the
  outcome is in doubt; poll the intent rather than executing again.
  `read_token` unlocks a private intent's settlement legs on a status read; it
  is a bearer secret and is left out of `inspect/1`.
  """
  import Raxol.Payments.Xochi.Schemas, only: [pick: 2]

  alias Raxol.Payments.Xochi.Schemas.Status

  # Statuses an execute response may carry; anything else reads as `:unknown`.
  @statuses ~w(pending pull_pending executing bridging settling source_finalized
               completed refund_pending refunded failed expired)a

  @derive {Inspect, except: [:read_token]}
  @enforce_keys [:intent_id, :status]
  defstruct [
    :intent_id,
    :status,
    :tx_hash,
    :note_commitment,
    :stealth_address,
    :ephemeral_pub_key,
    :view_tag,
    :error,
    :read_token,
    success: false,
    reconciling: false
  ]

  @type t :: %__MODULE__{
          success: boolean(),
          intent_id: String.t() | nil,
          status: atom(),
          tx_hash: String.t() | nil,
          note_commitment: String.t() | nil,
          stealth_address: String.t() | nil,
          ephemeral_pub_key: String.t() | nil,
          view_tag: integer() | nil,
          error: String.t() | nil,
          read_token: String.t() | nil,
          reconciling: boolean()
        }

  # Snake_case from the worker, camelCase from simulators; both are read.
  @spec from_json(map()) :: t()
  def from_json(json) do
    %__MODULE__{
      success: json["success"] || false,
      intent_id: pick(json, ["intent_id", "intentId"]),
      status: Status.parse(json["status"], @statuses),
      tx_hash: pick(json, ["tx_hash", "txHash"]),
      note_commitment: pick(json, ["note_commitment", "noteCommitment"]),
      stealth_address: pick(json, ["stealth_address", "stealthAddress"]),
      ephemeral_pub_key: pick(json, ["ephemeral_pub_key", "ephemeralPubKey"]),
      view_tag: pick(json, ["view_tag", "viewTag"]),
      error: json["error"],
      # In-doubt: the worker could not confirm the solver executed (a Riddler
      # 5xx/timeout wrapped as a 200) and kept the intent non-terminal. Funds
      # may be in flight; the caller must poll to resolve, never re-execute.
      reconciling: pick(json, ["reconciling"]) || false,
      # Read capability, returned once by execute, never coerced; the client
      # rejects a present malformed value.
      read_token: read_token(json)
    }
  end

  @doc """
  Is this a well-formed intent read token: 32 random bytes as unpadded
  base64url, so exactly 43 characters of `[A-Za-z0-9_-]`? Checked where a
  token enters (the execute response) and where one leaves (the request
  header), so a malformed value never reaches a header.
  """
  @spec read_token?(term()) :: boolean()
  def read_token?(token) when is_binary(token),
    do: String.match?(token, ~r/\A[A-Za-z0-9_-]{43}\z/)

  def read_token?(_), do: false

  defp read_token(json) do
    token = pick(json, ["read_token", "readToken"])
    if read_token?(token), do: token
  end
end

defmodule Raxol.Payments.Xochi.Schemas.IntentStatus do
  @moduledoc """
  An intent's status from `GET /api/intent/:id/status`.

  Terminal statuses are `:completed`, `:failed`, `:expired` and `:refunded`.
  `:refund_pending` and `:source_finalized` stay non-terminal even when the
  server flags them terminal. An unlisted status parses as `:unknown`.
  """
  import Raxol.Payments.Xochi.Schemas, only: [pick: 2]

  alias Raxol.Payments.Xochi.Schemas.Status

  @enforce_keys [:intent_id, :status]
  defstruct [
    :intent_id,
    :status,
    :tx_hash,
    :receiving_tx_hash,
    :error,
    # Solver-supplied reason a refunded intent was refunded (worker
    # `refundReason`); present only on the terminal `:refunded` status.
    :refund_reason,
    :updated_at,
    :substatus,
    :substatus_message,
    # PXE shielded settlement fields (present when settlement = :shielded)
    :note_commitment,
    :nullifier_hash,
    :l2_tx_hash,
    :settlement_type,
    :attestation_status,
    # The destination fill receipt and its chain (owner view only).
    :settlement_tx_hash,
    :settlement_chain_id,
    # Anonymous view of a private settlement: the legs are
    # withheld, and `settlement_confirmed` says whether the fill receipt
    # exists. Reporting markers only; never a reason to release or re-execute.
    settlement_confirmed: false,
    legs_withheld: false,
    terminal: false
  ]

  @type status :: Status.t()

  @type settlement_type :: :public | :stealth | :shielded | nil
  @type attestation_status :: :verified | :rejected | :not_required | nil

  @type t :: %__MODULE__{
          intent_id: String.t(),
          status: status(),
          tx_hash: String.t() | nil,
          receiving_tx_hash: String.t() | nil,
          error: String.t() | nil,
          refund_reason: String.t() | nil,
          updated_at: String.t() | nil,
          substatus: String.t() | nil,
          substatus_message: String.t() | nil,
          note_commitment: String.t() | nil,
          nullifier_hash: String.t() | nil,
          l2_tx_hash: String.t() | nil,
          settlement_type: settlement_type(),
          attestation_status: attestation_status(),
          settlement_tx_hash: String.t() | nil,
          settlement_chain_id: integer() | nil,
          settlement_confirmed: boolean(),
          legs_withheld: boolean(),
          terminal: boolean()
        }

  @terminal_statuses [:completed, :failed, :expired, :refunded]

  # Non-terminal whatever the server's `terminal` flag says: `refund_pending`
  # is a queued refund with no refund tx yet, and `source_finalized` is where a
  # shielded tracer intent rests, never `completed`. Polling continues and the
  # reservation stays until a terminal status.
  @held_statuses [:source_finalized, :refund_pending]

  # Snake_case from the worker, camelCase from simulators; both are read.
  @spec from_json(map()) :: t()
  def from_json(json) do
    status = Status.parse(json["status"])

    %__MODULE__{
      intent_id: pick(json, ["intent_id", "intentId"]),
      status: status,
      tx_hash: pick(json, ["tx_hash", "txHash"]),
      receiving_tx_hash: pick(json, ["receiving_tx_hash", "receivingTxHash"]),
      error: json["error"],
      refund_reason: pick(json, ["refund_reason", "refundReason"]),
      updated_at: pick(json, ["updated_at", "updatedAt"]),
      substatus: json["substatus"],
      substatus_message: pick(json, ["substatus_message", "substatusMessage"]),
      note_commitment: pick(json, ["note_commitment", "noteCommitment"]),
      nullifier_hash: pick(json, ["nullifier_hash", "nullifierHash"]),
      l2_tx_hash: pick(json, ["l2_tx_hash", "l2TxHash"]),
      settlement_type: parse_settlement_type(pick(json, ["settlement_type", "settlementType"])),
      attestation_status:
        parse_attestation_status(pick(json, ["attestation_status", "attestationStatus"])),
      settlement_tx_hash: string_or_nil(json["settlement_tx_hash"]),
      settlement_chain_id: integer_or_nil(json["settlement_chain_id"]),
      settlement_confirmed: json["settlement_confirmed"] == true,
      legs_withheld: json["legs_withheld"] == true,
      terminal: terminal_status?(status, json["terminal"])
    }
  end

  defp terminal_status?(status, _flag) when status in @held_statuses, do: false
  defp terminal_status?(status, flag), do: flag == true or status in @terminal_statuses

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{terminal: t}), do: t

  @doc """
  Whether the destination fill is confirmed: the anonymous view's
  `settlement_confirmed` marker, or the owner view's fill receipt. True while
  the top-level status may still be settling.
  """
  @spec settlement_confirmed?(t()) :: boolean()
  def settlement_confirmed?(%__MODULE__{settlement_confirmed: true}), do: true
  def settlement_confirmed?(%__MODULE__{settlement_tx_hash: hash}), do: is_binary(hash)

  @spec shielded?(t()) :: boolean()
  def shielded?(%__MODULE__{settlement_type: :shielded}), do: true
  def shielded?(%__MODULE__{note_commitment: c}) when is_binary(c), do: true
  def shielded?(_), do: false

  defp parse_settlement_type(nil), do: nil
  defp parse_settlement_type("public"), do: :public
  defp parse_settlement_type("stealth"), do: :stealth
  defp parse_settlement_type("shielded"), do: :shielded
  defp parse_settlement_type(_s), do: nil

  defp parse_attestation_status(nil), do: nil
  defp parse_attestation_status("verified"), do: :verified
  defp parse_attestation_status("rejected"), do: :rejected
  defp parse_attestation_status("not_required"), do: :not_required
  defp parse_attestation_status(_s), do: nil
end

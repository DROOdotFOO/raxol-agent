defmodule Raxol.Payments.Xochi.Schemas.DepositRouteRequest do
  @moduledoc """
  A cross-VM deposit-route quote request: a non-EVM origin (Tron) settling to
  an EVM destination. The origin has no gasless pull, so the quote returns a
  `deposit_address` (+ `deposit_attestation` to verify) instead of EIP-712
  typed data to sign.

  Serializes to the same `/api/intent/quote` wire keys as `QuoteRequest`, but
  validates the origin fields as Tron base58 and the destination fields as EVM
  `0x`-hex. Only a Tron origin is supported; other non-EVM origins reject at
  `validate/1`.

  Every field here is part of the v3 `deposit_attestation` the quote is verified
  against (`Raxol.Payments.Xochi.DepositAttestation`): the optional
  `refund_address` (Tron base58: where a failed deposit is returned, ahead of
  `wallet`) and stealth meta-address (`0x` + 33-byte compressed keys) are bound
  as sent, and an omitted one is bound as absent.
  """

  alias Raxol.Payments.Tron
  alias Raxol.Payments.Xochi.Schemas

  @tron_chain_id 728_126_428

  @enforce_keys [:wallet, :from_chain_id, :to_chain_id, :from_token, :to_token, :from_amount]
  defstruct [
    :wallet,
    :from_chain_id,
    :to_chain_id,
    :from_token,
    :to_token,
    :from_amount,
    :recipient_address,
    :refund_address,
    :stealth_spending_pub_key,
    :stealth_viewing_pub_key,
    :trust_score,
    settlement_preference: "public",
    slippage_bps: 50
  ]

  @type t :: %__MODULE__{
          wallet: String.t(),
          from_chain_id: pos_integer(),
          to_chain_id: pos_integer(),
          from_token: String.t(),
          to_token: String.t(),
          from_amount: String.t(),
          recipient_address: String.t() | nil,
          refund_address: String.t() | nil,
          stealth_spending_pub_key: String.t() | nil,
          stealth_viewing_pub_key: String.t() | nil,
          trust_score: non_neg_integer() | nil,
          settlement_preference: String.t(),
          slippage_bps: non_neg_integer()
        }

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = req) do
    cond do
      req.from_chain_id != @tron_chain_id ->
        {:error, {:unsupported_origin_vm, "deposit routes support a Tron origin only"}}

      not Tron.Address.valid?(req.wallet) ->
        {:error, {:invalid_wallet, "origin wallet must be a Tron base58 address"}}

      not Tron.Address.valid?(req.from_token) ->
        {:error, {:invalid_from_token, "origin token must be a Tron base58 address"}}

      req.to_chain_id < 1 ->
        {:error, {:invalid_chain_id, "to_chain_id must be positive"}}

      Schemas.validate_eth_address(req.to_token) != :ok ->
        {:error, {:invalid_to_token, "destination token must be 0x + 40 hex chars"}}

      # A cross-VM route pays an EVM destination distinct from the Tron wallet,
      # so a valid EVM recipient is required -- the wallet cannot receive on EVM.
      Schemas.validate_eth_address(req.recipient_address) != :ok ->
        {:error, {:invalid_recipient_address, "destination recipient must be 0x + 40 hex chars"}}

      not positive_int_string?(req.from_amount) ->
        {:error, {:invalid_from_amount, "must be a positive base-unit integer string"}}

      true ->
        validate_optionals(req)
    end
  end

  # The optional attested fields: absent is bound as absent, present must be
  # well-formed.
  defp validate_optionals(%__MODULE__{} = req) do
    cond do
      # A refund executes on the origin chain, so it is a Tron address.
      not (is_nil(req.refund_address) or Tron.Address.valid?(req.refund_address)) ->
        {:error, {:invalid_refund_address, "refund address must be a Tron base58 address"}}

      not optional_pub_key?(req.stealth_spending_pub_key) ->
        {:error, {:invalid_stealth_spending_pub_key, "must be 0x + 66 hex chars"}}

      not optional_pub_key?(req.stealth_viewing_pub_key) ->
        {:error, {:invalid_stealth_viewing_pub_key, "must be 0x + 66 hex chars"}}

      true ->
        :ok
    end
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = req) do
    %{
      "wallet" => req.wallet,
      "from_chain_id" => req.from_chain_id,
      "to_chain_id" => req.to_chain_id,
      "from_token" => req.from_token,
      "to_token" => req.to_token,
      "from_amount" => req.from_amount,
      "recipient_address" => req.recipient_address,
      "settlement_preference" => req.settlement_preference,
      "slippage_bps" => req.slippage_bps
    }
    |> Schemas.put_non_nil("trust_score", req.trust_score)
    |> Schemas.put_non_nil("refund_address", req.refund_address)
    |> Schemas.put_non_nil("stealth_spending_pub_key", req.stealth_spending_pub_key)
    |> Schemas.put_non_nil("stealth_viewing_pub_key", req.stealth_viewing_pub_key)
  end

  defp optional_pub_key?(nil), do: true

  defp optional_pub_key?("0x" <> hex) when byte_size(hex) == 66,
    do: match?({:ok, _}, Base.decode16(hex, case: :mixed))

  defp optional_pub_key?(_), do: false

  defp positive_int_string?(amount) when is_binary(amount) do
    match?({n, ""} when n > 0, Integer.parse(amount))
  end

  defp positive_int_string?(_), do: false
end

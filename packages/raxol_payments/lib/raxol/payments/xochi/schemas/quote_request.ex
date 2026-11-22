defmodule Raxol.Payments.Xochi.Schemas.QuoteRequest do
  @moduledoc """
  A Xochi intent quote request.

  `swap_kind` picks which amount the caller fixes. `"exact_input"` (default)
  sends `from_amount` and the solver computes `to_amount`. `"exact_output"`
  sends `output_amount` (destination atomic units) and the solver
  back-computes `from_amount`, so `from_amount` is nil and `max_from_amount`
  -- the most origin atomic units the caller will spend -- is required. It is
  never sent: it is the client-side ceiling `Protocols.Xochi.validate_intent/2`
  holds the signed `fromAmount` to.
  """
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Xochi.Schemas

  @enforce_keys [
    :wallet,
    :from_chain_id,
    :to_chain_id,
    :from_token,
    :to_token,
    :from_amount,
    :settlement_preference
  ]
  defstruct [
    :wallet,
    :from_chain_id,
    :to_chain_id,
    :from_token,
    :to_token,
    :from_amount,
    :recipient_address,
    :trust_score,
    :stealth_spending_pub_key,
    :stealth_viewing_pub_key,
    :output_amount,
    :max_from_amount,
    settlement_preference: "public",
    swap_kind: "exact_input",
    deadline: nil,
    slippage_bps: 50,
    gasless: false,
    attestations: []
  ]

  @type settlement :: String.t()

  @type t :: %__MODULE__{
          wallet: String.t(),
          from_chain_id: pos_integer(),
          to_chain_id: pos_integer(),
          from_token: String.t(),
          to_token: String.t(),
          from_amount: String.t() | nil,
          swap_kind: String.t(),
          output_amount: String.t() | nil,
          max_from_amount: String.t() | nil,
          recipient_address: String.t() | nil,
          settlement_preference: settlement(),
          deadline: integer() | nil,
          slippage_bps: non_neg_integer(),
          trust_score: non_neg_integer() | nil,
          stealth_spending_pub_key: String.t() | nil,
          stealth_viewing_pub_key: String.t() | nil,
          gasless: boolean(),
          attestations: [map()]
        }

  # Compressed secp256k1 public key: 0x + 02/03 prefix + 32 bytes (66 hex chars).
  @compressed_pubkey ~r/^0x0[23][a-fA-F0-9]{64}$/

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = req) do
    stealth? = req.settlement_preference == "stealth"

    [
      {Schemas.validate_eth_address(req.wallet) == :ok,
       {:invalid_wallet, "must be 0x + 40 hex chars"}},
      {Schemas.validate_eth_address(req.from_token) == :ok,
       {:invalid_from_token, "must be 0x + 40 hex chars"}},
      {Schemas.validate_eth_address(req.to_token) == :ok,
       {:invalid_to_token, "must be 0x + 40 hex chars"}},
      {req.from_chain_id >= 1, {:invalid_chain_id, "from_chain_id must be positive"}},
      {req.to_chain_id >= 1, {:invalid_chain_id, "to_chain_id must be positive"}},
      {not stealth? or stealth_keys_present?(req),
       {:stealth_keys_required,
        "stealth settlement requires compressed spending and viewing public keys"}},
      # ERC-5564 stealth addresses are secp256k1/keccak EVM addresses. Checked
      # on the request every quote path sends, so no caller can ask for a
      # stealth settlement on Tron, Solana, or a chain this build does not know.
      {not stealth? or req.to_chain_id in Assets.evm_chain_ids(), :stealth_unsupported_on_chain},
      {recipient_address_valid?(req.recipient_address),
       {:invalid_recipient_address, "must be a non-empty string when set"}}
    ]
    |> Enum.find_value(:ok, fn {ok?, reason} -> if not ok?, do: {:error, reason} end)
    |> then(fn
      :ok -> validate_swap_kind(req)
      error -> error
    end)
  end

  @digits ~r/\A[0-9]{1,78}\z/

  # Exactly one caller-fixed amount per kind, as Riddler requires. exact_output
  # also needs the ceiling, since nothing else bounds what leaves the wallet.
  defp validate_swap_kind(%__MODULE__{swap_kind: "exact_input", output_amount: nil}), do: :ok

  defp validate_swap_kind(%__MODULE__{swap_kind: "exact_input"}),
    do: {:error, {:invalid_output_amount, "must be omitted for exact_input"}}

  defp validate_swap_kind(%__MODULE__{swap_kind: "exact_output"} = req) do
    cond do
      not digits?(req.output_amount) ->
        {:error, {:invalid_output_amount, "exact_output requires output_amount in atomic units"}}

      not digits?(req.max_from_amount) ->
        {:error,
         {:invalid_max_from_amount, "exact_output requires max_from_amount in atomic units"}}

      not is_nil(req.from_amount) ->
        {:error, {:invalid_from_amount, "must be omitted for exact_output"}}

      true ->
        :ok
    end
  end

  defp validate_swap_kind(%__MODULE__{swap_kind: kind}),
    do: {:error, {:invalid_swap_kind, kind}}

  defp digits?(value) when is_binary(value), do: Regex.match?(@digits, value)
  defp digits?(_), do: false

  # `recipient_address` is optional: nil lets Riddler default it to `wallet`
  # (same-VM). When set (required for a cross-VM route, e.g. an EVM wallet
  # paying a Tron address), it must be a non-empty string. The chain-specific
  # format (EVM `0x`-hex vs TVM/SVM base58) is validated by Riddler against
  # `to_chain_id`, which owns the chain->VM mapping.
  defp recipient_address_valid?(nil), do: true
  defp recipient_address_valid?(addr) when is_binary(addr), do: addr != ""
  defp recipient_address_valid?(_), do: false

  defp stealth_keys_present?(%__MODULE__{
         stealth_spending_pub_key: spend,
         stealth_viewing_pub_key: view
       }) do
    compressed_pubkey?(spend) and compressed_pubkey?(view)
  end

  defp compressed_pubkey?(key) when is_binary(key),
    do: Regex.match?(@compressed_pubkey, key)

  defp compressed_pubkey?(_), do: false

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = req) do
    base = %{
      "wallet" => req.wallet,
      "from_chain_id" => req.from_chain_id,
      "to_chain_id" => req.to_chain_id,
      "from_token" => req.from_token,
      "to_token" => req.to_token,
      "settlement_preference" => req.settlement_preference,
      "deadline" => req.deadline || :os.system_time(:second) + 300,
      "slippage_bps" => req.slippage_bps,
      "gasless" => req.gasless
    }

    base
    |> put_amount(req)
    |> Schemas.put_non_nil("recipient_address", req.recipient_address)
    |> Schemas.put_non_nil("trust_score", req.trust_score)
    |> Schemas.put_non_nil(
      "stealth_spending_pub_key",
      req.stealth_spending_pub_key
    )
    |> Schemas.put_non_nil(
      "stealth_viewing_pub_key",
      req.stealth_viewing_pub_key
    )
    |> maybe_put_attestations(req.attestations)
  end

  # exact_input sends from_amount and leaves the kind to Riddler's default;
  # exact_output names its kind and omits from_amount, which Riddler rejects.
  defp put_amount(map, %__MODULE__{swap_kind: "exact_output"} = req) do
    Map.merge(map, %{"swap_kind" => "exact_output", "output_amount" => req.output_amount})
  end

  defp put_amount(map, %__MODULE__{} = req), do: Map.put(map, "from_amount", req.from_amount)

  defp maybe_put_attestations(map, []), do: map

  defp maybe_put_attestations(map, attestations) when is_list(attestations) do
    Map.put(map, "attestations", Enum.map(attestations, &attestation_to_json/1))
  end

  defp attestation_to_json(
         %{
           type_code: code,
           issuer: issuer,
           subject: subject,
           issued_at: issued,
           expires_at: expires,
           signature: sig
         } = proof
       ) do
    base = %{
      "typeCode" => code,
      "issuer" => issuer,
      "subject" => subject,
      "issuedAt" => issued,
      "expiresAt" => expires,
      "signature" => sig
    }

    case Map.get(proof, :payload) do
      nil ->
        base

      payload when is_binary(payload) ->
        Map.put(base, "payload", Base.encode16(payload, case: :lower))
    end
  end
end

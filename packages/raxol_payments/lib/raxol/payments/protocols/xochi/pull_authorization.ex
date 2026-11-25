defmodule Raxol.Payments.Protocols.Xochi.PullAuthorization do
  @moduledoc false
  # The origin pull: a second EIP-712 the agent signs so the solver can collect
  # origin funds before settling. `erc3009` is ReceiveWithAuthorization (USDC
  # domain, no approval); `permit2` is PermitWitnessTransferFrom (needs a
  # standing Permit2 approval). A hostile quote could name an attacker
  # recipient for the full balance, and the SpendGate sees only the intended
  # human amount, so the served pull is bound to the request before signing.
  # Public entry points are delegated from `Raxol.Payments.Protocols.Xochi`.

  alias Raxol.Payments.{Assets, EIP712, TypedData}
  alias Raxol.Payments.Assets.UsdcDomains
  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Protocols.Xochi.EIP712, as: Served
  alias Raxol.Payments.Protocols.Xochi.SolverPin
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  # The served payload must be exactly the canonical struct for the method
  # (primary type, every type with its ordered fields, the message's fields and
  # the domain), so a payload that adds a type, retypes a field, carries an
  # extra signable field, or names another domain is refused before signing.
  @erc3009_kind %{
    primary: "ReceiveWithAuthorization",
    types: %{
      "ReceiveWithAuthorization" => [
        {"from", "address"},
        {"to", "address"},
        {"value", "uint256"},
        {"validAfter", "uint256"},
        {"validBefore", "uint256"},
        {"nonce", "bytes32"}
      ]
    },
    # EIP-3009 RECEIVE_WITH_AUTHORIZATION_TYPEHASH.
    type_hash:
      Base.decode16!("d099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8",
        case: :lower
      )
  }
  @permit2_kind %{
    primary: "PermitWitnessTransferFrom",
    types: Permit2.types(),
    # keccak256("PermitWitnessTransferFrom(TokenPermissions permitted,address spender,
    # uint256 nonce,uint256 deadline,OriginPullWitness witness)OriginPullWitness(bytes32
    # orderId)TokenPermissions(address token,uint256 amount)"), SPEC.md section 2.3.
    type_hash:
      Base.decode16!("4409a64154fcc59d975b06e8a233149d93d9fe0311a3d359f399a4333b11c3f5",
        case: :lower
      )
  }

  @spec permit2_kind() :: TypedData.kind()
  def permit2_kind, do: @permit2_kind

  @spec validate(QuoteResponse.t(), QuoteRequest.t(), module()) :: :ok | {:error, term()}
  def validate(%QuoteResponse{pull_authorization: nil}, _request, _wallet), do: :ok

  def validate(
        %QuoteResponse{pull_authorization: pull, payment_method: method},
        %QuoteRequest{} = request,
        wallet
      ) do
    case method do
      "erc3009" ->
        validate_erc3009(pull, request, wallet.address())

      "permit2" ->
        validate_permit2(pull, request.from_token, request.from_chain_id, ceiling(request))

      other ->
        {:error, {:authorization_mismatch, {:unsupported_pull_method, other}}}
    end
  end

  @doc """
  Sign the served pull under the canonical types for its method, or return
  `{:ok, nil}` when the quote carries no pull.
  """
  @spec sign(QuoteResponse.t(), module()) :: {:ok, String.t() | nil} | {:error, term()}
  def sign(%QuoteResponse{pull_authorization: nil}, _wallet), do: {:ok, nil}

  def sign(%QuoteResponse{pull_authorization: pull, payment_method: method}, wallet) do
    with {:ok, %{types: types}} <- kind(method) do
      case Served.sign(pull, types, wallet) do
        {:ok, signature} -> {:ok, signature}
        {:error, reason} -> {:error, {:pull_sign_failed, reason}}
      end
    end
  end

  # `verifyingContract` is pinned to the canonical Permit2 because it decides
  # who checks this signature: left to the quote, the payload could nominate a
  # verifier that agrees with whatever it served, while the allowance being
  # spent was granted to Permit2. The spender pin is always required.
  @spec validate_permit2(term(), String.t(), pos_integer(), term()) ::
          :ok | {:error, {:authorization_mismatch, term()}}
  def validate_permit2(pull, token, chain_id, ceiling) when is_map(pull) do
    domain = %{
      "name" => "Permit2",
      "chainId" => chain_id,
      "verifyingContract" => Permit2.verifying_contract()
    }

    with :ok <- typed_data(pull, @permit2_kind, domain, :pull_verifier) do
      message = pull["message"]
      permitted = message["permitted"]

      first_mismatch([
        {:pull_token, addr_match?(permitted["token"], token)},
        {:pull_value, Served.uint_within?(permitted["amount"], ceiling)},
        {:pull_spender, SolverPin.allowed?(message["spender"], :permit2)},
        {:pull_expiry, valid_window?(message["deadline"])}
      ])
    end
  end

  def validate_permit2(_pull, _token, _chain_id, _ceiling),
    do: {:error, {:authorization_mismatch, :pull_type}}

  defp kind("erc3009"), do: {:ok, @erc3009_kind}
  defp kind("permit2"), do: {:ok, @permit2_kind}
  defp kind(other), do: {:error, {:authorization_mismatch, {:unsupported_pull_method, other}}}

  # ERC-3009 is USDC's (SPEC.md section 2.3): the origin token must be USDC on
  # its chain and the domain is that token's own name/version, chain and
  # contract. `from` is the signer, `value` the pulled amount, `validBefore`
  # the expiry, `to` the solver collection address under the solver pin.
  defp validate_erc3009(pull, request, signer) do
    message = Served.message(pull)

    with :ok <- erc3009_token(request),
         :ok <- typed_data(pull, @erc3009_kind, erc3009_domain(request), :pull_token) do
      first_mismatch([
        {:pull_from, addr_match?(message["from"], signer)},
        {:pull_value, Served.uint_within?(message["value"], ceiling(request))},
        {:pull_to, SolverPin.allowed?(message["to"], :erc3009)},
        {:pull_expiry, valid_window?(message["validBefore"])}
      ])
    end
  end

  defp erc3009_token(%QuoteRequest{from_chain_id: chain, from_token: token}) do
    if Assets.symbol_for(chain, token) == "USDC" and chain in UsdcDomains.known_chain_ids(),
      do: :ok,
      else: {:error, {:authorization_mismatch, :pull_token}}
  end

  defp erc3009_domain(%QuoteRequest{from_chain_id: chain, from_token: token}) do
    %{name: name, version: version} = UsdcDomains.lookup(chain)
    %{"name" => name, "version" => version, "chainId" => chain, "verifyingContract" => token}
  end

  # Shape, then domain: `:pull_type` for the types or primary type,
  # `:pull_fields` for the message's fields, `:pull_chain` for `chainId`,
  # `verifier_field` for `verifyingContract`, `{:pull_domain, key}` otherwise.
  defp typed_data(pull, kind, expected_domain, verifier_field) do
    case TypedData.check_shape(pull, kind) do
      :ok ->
        case TypedData.check_domain(pull["domain"], expected_domain) do
          :ok ->
            :ok

          {:error, {:domain, :chain_id}} ->
            {:error, {:authorization_mismatch, :pull_chain}}

          {:error, {:domain, :verifying_contract}} ->
            {:error, {:authorization_mismatch, verifier_field}}

          {:error, {:domain, key}} ->
            {:error, {:authorization_mismatch, {:pull_domain, key}}}
        end

      {:error, :message_fields} ->
        {:error, {:authorization_mismatch, :pull_fields}}

      {:error, _type_mismatch} ->
        {:error, {:authorization_mismatch, :pull_type}}
    end
  end

  # The most the pull may authorize: the exact origin amount on `exact_input`,
  # the caller's ceiling on `exact_output` (the solver picks the amount).
  defp ceiling(%QuoteRequest{swap_kind: "exact_output", max_from_amount: max}), do: max
  defp ceiling(%QuoteRequest{from_amount: from_amount}), do: from_amount

  # A real future expiry within `:pull_max_validity_seconds` (default 1 hour),
  # so a hostile quote cannot get a standing pull signed.
  defp valid_window?(value) do
    now = System.system_time(:second)
    max_ahead = Application.get_env(:raxol_payments, :pull_max_validity_seconds, 3600)

    case Served.uint(value) do
      t when is_integer(t) -> t > now and t <= now + max_ahead
      _ -> false
    end
  end

  defp first_mismatch(checks) do
    case Enum.find(checks, fn {_field, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:authorization_mismatch, field}}
    end
  end

  # Both sides must normalize to a canonical 20-byte hex address, so a
  # malformed value is rejected rather than matched loosely.
  defp addr_match?(a, b) when is_binary(a) and is_binary(b) do
    na = EIP712.normalize_address(a)
    valid_address?(na) and na == EIP712.normalize_address(b)
  end

  defp addr_match?(_, _), do: false

  defp valid_address?(<<hex::binary-size(40)>>), do: String.match?(hex, ~r/\A[0-9a-f]{40}\z/)
  defp valid_address?(_), do: false
end

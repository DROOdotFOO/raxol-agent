defmodule Raxol.Payments.Protocols.Xochi.IntentValidation do
  @moduledoc false
  # Binds a served `XochiIntent` to the caller's `QuoteRequest` before the
  # wallet signs it. Public entry points are delegated from
  # `Raxol.Payments.Protocols.Xochi`, which documents them.

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi.EIP712, as: Served
  alias Raxol.Payments.TypedData
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  # XochiIntent v3, `@xochi/spec` SPEC.md section 2.1: the only struct the
  # agent signs as an intent, fields in order. The type hash is keccak256 of
  # "XochiIntent(string intentId,string quoteId,address wallet,string recipient,
  # uint256 fromChainId,uint256 toChainId,string fromToken,string toToken,
  # uint256 fromAmount,uint256 toAmount,string settlementPreference,uint256 deadline)".
  @intent_types %{
    "XochiIntent" => [
      {"intentId", "string"},
      {"quoteId", "string"},
      {"wallet", "address"},
      {"recipient", "string"},
      {"fromChainId", "uint256"},
      {"toChainId", "uint256"},
      {"fromToken", "string"},
      {"toToken", "string"},
      {"fromAmount", "uint256"},
      {"toAmount", "uint256"},
      {"settlementPreference", "string"},
      {"deadline", "uint256"}
    ]
  }
  @intent_kind %{
    primary: "XochiIntent",
    types: @intent_types,
    type_hash:
      Base.decode16!("4fa2b313c9b182c2ea701a5a9c932b340c256ea2c2135b5456c792ccd59c64b6",
        case: :lower
      )
  }

  # Riddler issues quotes valid for ~300s; an hour of headroom tolerates a slow
  # local clock. A fast clock fails open: the wall clock is the one value on
  # this path the server does not supply. Riddler's SDK applies the same bound.
  @max_deadline_ahead_seconds 3600

  @spec kind() :: TypedData.kind()
  def kind, do: @intent_kind

  @spec validate(QuoteResponse.t(), QuoteRequest.t()) :: :ok | {:error, term()}
  def validate(%QuoteResponse{eip712_data: nil}, %QuoteRequest{}), do: {:error, :no_eip712_data}

  def validate(%QuoteResponse{eip712_data: eip712}, %QuoteRequest{}) when not is_map(eip712),
    do: {:error, {:intent_mismatch, :intent_type}}

  def validate(%QuoteResponse{eip712_data: eip712} = quote_resp, %QuoteRequest{} = request) do
    with :ok <- typed_data(eip712, request) do
      message = Served.message(eip712)

      mismatch(
        Enum.concat([
          route_checks(message, request),
          [
            {:deadline, deadline_bounded?(message["deadline"])},
            {:quoted_to_amount, Served.uint_match?(message["toAmount"], quote_resp.to_amount)}
          ],
          amount_checks(message, request)
        ])
      )
    end
  end

  @spec from_amount(QuoteResponse.t()) :: String.t() | nil
  def from_amount(%QuoteResponse{eip712_data: %{"message" => %{} = message}}) do
    case Served.uint(message["fromAmount"]) do
      n when is_integer(n) -> Integer.to_string(n)
      nil -> nil
    end
  end

  def from_amount(%QuoteResponse{}), do: nil

  @doc "Sign the validated intent under the canonical `XochiIntent` types."
  @spec sign(QuoteResponse.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def sign(%QuoteResponse{eip712_data: eip712}, wallet) do
    case Served.sign(eip712, @intent_types, wallet) do
      {:ok, signature} -> {:ok, signature}
      {:error, reason} -> {:error, {:sign_failed, reason}}
    end
  end

  # The envelope: exactly the v3 types, a message with exactly its fields, and
  # the SPEC.md section 2.2 domain: name "Xochi", a v3 version, chainId = the
  # request's origin chain, salt = keccak256(version), no verifyingContract.
  defp typed_data(eip712, request) do
    case TypedData.check_shape(eip712, @intent_kind) do
      :ok ->
        case TypedData.check_domain(eip712["domain"], domain(eip712, request)) do
          :ok -> :ok
          {:error, {:domain, key}} -> {:error, {:intent_mismatch, {:intent_domain, key}}}
        end

      {:error, :message_fields} ->
        {:error, {:intent_mismatch, :intent_fields}}

      {:error, _type_mismatch} ->
        {:error, {:intent_mismatch, :intent_type}}
    end
  end

  # The domain `version` is deployment-scoped ("3", or a scoped "3-prod"), but
  # its major is the struct version, so only a v3 version is accepted.
  defp domain(eip712, %QuoteRequest{from_chain_id: chain_id}) do
    version =
      case get_in(eip712, ["domain", "version"]) do
        v when is_binary(v) -> if domain_version?(v), do: v
        _ -> nil
      end

    %{
      "name" => "Xochi",
      "version" => version,
      "chainId" => chain_id,
      "salt" => if(version, do: keccak_hex(version))
    }
  end

  defp domain_version?(version), do: Regex.match?(~r/\A3(-[a-z0-9]+)*\z/, version)

  defp keccak_hex(value), do: "0x" <> Base.encode16(ExKeccak.hash_256(value), case: :lower)

  # Who pays whom, on which chains and tokens, settled how.
  defp route_checks(message, %QuoteRequest{} = request) do
    [
      {:wallet, addressish_match?(message["wallet"], request.wallet)},
      {:from_chain_id, Served.uint_match?(message["fromChainId"], request.from_chain_id)},
      {:to_chain_id, Served.uint_match?(message["toChainId"], request.to_chain_id)},
      {:from_token, addressish_match?(message["fromToken"], request.from_token)},
      {:to_token, addressish_match?(message["toToken"], request.to_token)},
      {:recipient,
       addressish_match?(message["recipient"], request.recipient_address || request.wallet)},
      {:settlement_preference,
       message["settlementPreference"] == (request.settlement_preference || "public")}
    ]
  end

  # `swap_kind` decides which amount the caller chose. Comparing the
  # server-derived one for equality would reject every honest quote; on
  # `exact_output` it is what leaves the wallet, so it gets the ceiling instead.
  defp amount_checks(message, %QuoteRequest{swap_kind: "exact_output"} = request) do
    [
      {:to_amount, Served.uint_match?(message["toAmount"], request.output_amount)},
      {:max_from_amount, is_integer(Served.uint(request.max_from_amount))},
      {:from_amount, Served.uint_within?(message["fromAmount"], request.max_from_amount)}
    ]
  end

  defp amount_checks(message, %QuoteRequest{swap_kind: "exact_input"} = request),
    do: [{:from_amount, Served.uint_match?(message["fromAmount"], request.from_amount)}]

  defp amount_checks(_message, %QuoteRequest{}), do: [{:swap_kind, false}]

  # No lower bound: a lapsed deadline is the server's to reject.
  defp deadline_bounded?(value) do
    case Served.uint(value) do
      t when is_integer(t) -> t <= System.system_time(:second) + @max_deadline_ahead_seconds
      nil -> false
    end
  end

  defp mismatch(checks) do
    case Enum.find(checks, fn {_field, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:intent_mismatch, field}}
    end
  end

  # Riddler signs an EVM (0x-hex) wallet, token, or recipient lowercased and a
  # base58 (TVM/SVM) one verbatim, since base58 is case-sensitive. The served
  # value must carry no surrounding whitespace: `recipient` is a signed string.
  defp addressish_match?(served, requested)
       when is_binary(served) and is_binary(requested) and served != "" do
    String.trim(served) == served and addressish(served) == addressish(requested)
  end

  defp addressish_match?(_, _), do: false

  defp addressish(<<prefix::binary-size(2), _::binary>> = value) when prefix in ["0x", "0X"],
    do: {:evm, EIP712.normalize_address(value)}

  defp addressish(value), do: {:verbatim, value}
end

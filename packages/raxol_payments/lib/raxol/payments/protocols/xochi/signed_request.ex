defmodule Raxol.Payments.Protocols.Xochi.SignedRequest do
  @moduledoc false
  # The relayable signed-intent bundle: built from a signed quote on the buyer
  # side, and checked into an `ExecuteRequest` on the relay side without
  # re-signing.

  import Bitwise, only: [band: 2, bsl: 2]

  alias Raxol.Payments.Protocols.Xochi.EIP712, as: Served
  alias Raxol.Payments.Xochi.Schemas.{ExecuteRequest, QuoteResponse}

  @low_48_bits bsl(1, 48) - 1

  @doc """
  Assemble the bundle from a signed quote. `pull_signature` is present only
  when the quote carried an origin pull, so a non-pulling bundle serializes
  without a null `pull_signature`.
  """
  @spec build(QuoteResponse.t(), String.t(), String.t() | nil) :: map()
  def build(%QuoteResponse{} = quote_resp, signature, pull_signature) do
    bundle = %{
      intent_id: quote_resp.intent_id,
      quote_id: quote_resp.quote_id,
      signature: signature,
      nonce: nonce(quote_resp),
      deadline: deadline(quote_resp)
    }

    if pull_signature, do: Map.put(bundle, :pull_signature, pull_signature), else: bundle
  end

  @doc """
  Build an `ExecuteRequest` from a buyer-supplied bundle, failing closed with
  `{:error, {:invalid_signed_intent, field}}` on a missing or malformed field.
  Keys may be atoms or strings; `nonce` must be a non-negative integer.
  """
  @spec to_execute_request(map()) :: {:ok, ExecuteRequest.t()} | {:error, term()}
  def to_execute_request(signed) when is_map(signed) do
    with {:ok, intent_id} <- require_binary(signed, :intent_id),
         {:ok, quote_id} <- require_binary(signed, :quote_id),
         {:ok, signature} <- require_binary(signed, :signature),
         {:ok, nonce} <- require_nonce(signed),
         {:ok, deadline} <- optional_integer(signed, :deadline),
         {:ok, pull_signature} <- optional_binary(signed, :pull_signature),
         {:ok, aztec_proof} <- optional_binary(signed, :aztec_proof) do
      {:ok,
       %ExecuteRequest{
         intent_id: intent_id,
         quote_id: quote_id,
         signature: signature,
         nonce: nonce,
         deadline: deadline,
         pull_signature: pull_signature,
         aztec_proof: aztec_proof
       }}
    end
  end

  defp fetch_field(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end

  defp require_binary(map, field) do
    case fetch_field(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_signed_intent, field}}
    end
  end

  defp require_nonce(map) do
    case fetch_field(map, :nonce) do
      {:ok, nonce} when is_integer(nonce) and nonce >= 0 -> {:ok, nonce}
      _ -> {:error, {:invalid_signed_intent, :nonce}}
    end
  end

  defp optional_integer(map, field) do
    case fetch_field(map, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} when is_binary(value) -> parse_optional_integer(value, field)
      _ -> {:error, {:invalid_signed_intent, field}}
    end
  end

  defp parse_optional_integer(value, field) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, {:invalid_signed_intent, field}}
    end
  end

  defp optional_binary(map, field) do
    case fetch_field(map, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_signed_intent, field}}
    end
  end

  defp deadline(%QuoteResponse{eip712_data: eip712}) do
    case Served.message(eip712)["deadline"] do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The execute `nonce` is the worker's replay-dedup key (wallet, nonce), not
  # part of the intent signature: XochiIntent v3 has no nonce field. A constant
  # would make the worker reject a wallet's second non-terminal intent, so it is
  # derived from the pull authorization's server-issued nonce, else 0.
  defp nonce(%QuoteResponse{pull_authorization: %{"message" => %{"nonce" => nonce}}}),
    do: replay_nonce(nonce)

  defp nonce(_quote_resp), do: 0

  # The pull nonce's low 48 bits: unique per intent and within the worker's JS
  # Number range (< 2^53). ERC-3009 serves a bytes32 as 0x-hex; Permit2 a
  # uint256 as a decimal string or integer. A malformed value falls back to 0.
  defp replay_nonce("0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) >= 6 ->
        <<low::unsigned-big-48>> = binary_part(bytes, byte_size(bytes) - 6, 6)
        low

      _ ->
        0
    end
  end

  defp replay_nonce(nonce) do
    case Served.uint(nonce) do
      n when is_integer(n) -> band(n, @low_48_bits)
      nil -> 0
    end
  end
end

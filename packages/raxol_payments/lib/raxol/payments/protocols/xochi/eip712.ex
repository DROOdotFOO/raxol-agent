defmodule Raxol.Payments.Protocols.Xochi.EIP712 do
  @moduledoc false
  # Reading a served EIP-712 payload (`%{"domain", "types", "message"}` with
  # string keys) into what the wallet signs, and the uint256 values inside it,
  # which the worker serves as JSON integers or decimal strings.

  @domain_fields [
    {:name, "name"},
    {:version, "version"},
    {:chainId, "chainId"},
    {:verifyingContract, "verifyingContract"},
    {:salt, "salt"}
  ]

  # Every field is conditional: `Raxol.Payments.EIP712` derives the
  # EIP712Domain field list from the keys present, so a key carrying `nil`
  # would still declare that field and hash a domain the verifier never built.
  @spec domain(map()) :: map()
  def domain(eip712) do
    served = eip712["domain"] || %{}

    Enum.reduce(@domain_fields, %{}, fn {key, served_key}, domain ->
      case served[served_key] do
        nil -> domain
        value -> Map.put(domain, key, value)
      end
    end)
  end

  # `EIP712Domain` is dropped: left in, it would be a second root type and make
  # the primary type ambiguous.
  @spec types(map()) :: map()
  def types(eip712) do
    (eip712["types"] || %{})
    |> Map.drop(["EIP712Domain"])
    |> Enum.into(%{}, fn {name, fields} ->
      {name, Enum.map(fields, fn f -> {f["name"], f["type"]} end)}
    end)
  end

  @spec message(map() | nil) :: map()
  def message(%{"message" => %{} = message}), do: message
  def message(_eip712), do: %{}

  @doc """
  Sign the served payload's domain and message under the canonical `types`
  (never the served ones), returning the `0x` hex signature.
  """
  @spec sign(map(), map(), module()) :: {:ok, String.t()} | {:error, term()}
  def sign(payload, types, wallet) do
    case wallet.sign_typed_data(domain(payload), types, message(payload)) do
      {:ok, sig_bytes} -> {:ok, "0x" <> Base.encode16(sig_bytes, case: :lower)}
      {:error, _reason} = error -> error
    end
  end

  @spec uint(term()) :: non_neg_integer() | nil
  def uint(v) when is_integer(v) and v >= 0, do: v

  def uint(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  def uint(_), do: nil

  @spec uint_match?(term(), term()) :: boolean()
  def uint_match?(a, b) do
    case {uint(a), uint(b)} do
      {n, n} when is_integer(n) -> true
      _ -> false
    end
  end

  @spec uint_within?(term(), term()) :: boolean()
  def uint_within?(value, limit) do
    case {uint(value), uint(limit)} do
      {v, l} when is_integer(v) and is_integer(l) -> v <= l
      _ -> false
    end
  end
end

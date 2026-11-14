defmodule Raxol.Payments.TypedData do
  @moduledoc """
  Checks that a served EIP-712 payload is exactly the canonical typed data for
  one message kind, before anything signs it.

  A served payload carries its own `types`, `primaryType`, `domain` and
  `message`. Checking only that some field names are present lets a hostile
  server add types that change which struct gets hashed, retype a field, add
  signable fields, or name its own domain. So every served payload a signing
  path accepts must have:

    * `primaryType` equal to the expected primary type;
    * `types` (less `EIP712Domain`) equal to the canonical map, each struct's
      ordered `{name, type}` list included, so the hashed root is the expected
      one and its `typeHash` equals the canonical constant;
    * a `message` with exactly the canonical fields, nested structs included;
    * a domain with exactly the expected fields and values.

  Signing paths then sign with the canonical constants, not the served map.
  """

  alias Raxol.Payments.EIP712

  @typedoc """
  A message kind: its primary type, canonical types (string names and types, in
  field order) and the `typeHash` those types must encode to.
  """
  @type kind :: %{primary: String.t(), types: map(), type_hash: binary()}

  @typedoc """
  Expected domain values by served key (`"name"`, `"version"`, `"chainId"`,
  `"verifyingContract"`, `"salt"`). A key absent here must be absent from the
  served domain.
  """
  @type expected_domain :: %{optional(String.t()) => term()}

  @doc """
  Check the served payload's `primaryType`, `types` and `message` against
  `kind`. Returns `:ok` or `{:error, reason}` with reason one of
  `:primary_type`, `:types`, `:type_hash`, `:message_fields`.
  """
  @spec check_shape(map(), kind()) :: :ok | {:error, atom()}
  def check_shape(served, %{primary: primary, types: types, type_hash: type_hash})
      when is_map(served) do
    projected = project_types(served["types"])

    cond do
      served["primaryType"] != primary -> {:error, :primary_type}
      projected != types -> {:error, :types}
      EIP712.primary_type(projected) != primary -> {:error, :primary_type}
      EIP712.type_hash(primary, projected) != type_hash -> {:error, :type_hash}
      not exact_fields?(served["message"], primary, types) -> {:error, :message_fields}
      true -> :ok
    end
  end

  def check_shape(_served, _kind), do: {:error, :types}

  @doc """
  Check the served domain against `expected`: exactly the expected keys, with
  `name`/`version` compared as strings, `chainId` as an integer,
  `verifyingContract` as a case-insensitive address and `salt` as
  case-insensitive hex. Returns `:ok` or `{:error, {:domain, key}}` naming the
  first key that differs (`:fields` for a missing or extra key).
  """
  @spec check_domain(term(), expected_domain()) :: :ok | {:error, {:domain, atom()}}
  def check_domain(served, expected) when is_map(served) and is_map(expected) do
    if Enum.sort(Map.keys(served)) == Enum.sort(Map.keys(expected)) do
      Enum.find_value(expected, :ok, fn {key, value} ->
        if domain_value_match?(key, served[key], value),
          do: false,
          else: {:error, {:domain, domain_key(key)}}
      end)
    else
      {:error, {:domain, :fields}}
    end
  end

  def check_domain(_served, _expected), do: {:error, {:domain, :fields}}

  @doc """
  The domain map `Raxol.Payments.EIP712` hashes, built from `expected` (already
  checked equal to the served domain).
  """
  @spec signing_domain(expected_domain()) :: map()
  def signing_domain(expected) do
    Enum.into(expected, %{}, fn
      {"name", v} -> {:name, v}
      {"version", v} -> {:version, v}
      {"chainId", v} -> {:chainId, to_int(v)}
      {"verifyingContract", v} -> {:verifyingContract, v}
      {"salt", v} -> {:salt, v}
    end)
  end

  @doc """
  The served `types` projected to `%{name => [{field, type}]}`, without
  `EIP712Domain`. A malformed entry projects to `:invalid`, which no canonical
  map equals.
  """
  @spec project_types(term()) :: map() | :invalid
  def project_types(types) when is_map(types) do
    types
    |> Map.drop(["EIP712Domain"])
    |> Enum.reduce_while(%{}, fn
      {name, fields}, acc when is_binary(name) and is_list(fields) ->
        case project_fields(fields) do
          {:ok, projected} -> {:cont, Map.put(acc, name, projected)}
          :error -> {:halt, :invalid}
        end

      _other, _acc ->
        {:halt, :invalid}
    end)
  end

  def project_types(_types), do: :invalid

  defp project_fields(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn
      %{"name" => name, "type" => type} = field, {:ok, acc}
      when is_binary(name) and is_binary(type) and map_size(field) == 2 ->
        {:cont, {:ok, [{name, type} | acc]}}

      _field, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # The message, and each nested struct value, carries exactly the struct's
  # field names as keys: nothing missing, nothing extra.
  defp exact_fields?(message, type_name, types) when is_map(message) do
    fields = Map.fetch!(types, type_name)
    names = Enum.map(fields, &elem(&1, 0))

    Enum.sort(Map.keys(message)) == Enum.sort(names) and
      Enum.all?(fields, fn {name, type} ->
        if Map.has_key?(types, type),
          do: exact_fields?(message[name], type, types),
          else: true
      end)
  end

  defp exact_fields?(_message, _type_name, _types), do: false

  defp domain_value_match?("chainId", served, expected) do
    expected = to_int(expected)
    is_integer(expected) and to_int(served) == expected
  end

  defp domain_value_match?(key, served, expected)
       when key in ["verifyingContract", "salt"] and is_binary(served) and is_binary(expected),
       do: String.downcase(served) == String.downcase(expected)

  defp domain_value_match?(_key, served, expected) when is_binary(served),
    do: served == expected

  defp domain_value_match?(_key, _served, _expected), do: false

  defp domain_key("name"), do: :name
  defp domain_key("version"), do: :version
  defp domain_key("chainId"), do: :chain_id
  defp domain_key("verifyingContract"), do: :verifying_contract
  defp domain_key("salt"), do: :salt

  defp to_int(v) when is_integer(v) and v >= 0, do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_int(_v), do: nil
end

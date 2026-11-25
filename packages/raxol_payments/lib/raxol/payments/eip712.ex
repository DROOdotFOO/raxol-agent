defmodule Raxol.Payments.EIP712 do
  @moduledoc """
  EIP-712 typed-structured-data hashing.

  Produces the 32-byte digest defined by EIP-712:

      keccak256(0x19 || 0x01 || domainSeparator || hashStruct(message))

  The digest can then be passed to `ExSecp256k1.sign/2` (or any other
  secp256k1 signer) to produce the EIP-712 signature.

  Used by wallet implementations (`Raxol.Payments.Wallets.Env`,
  `Raxol.Payments.Wallets.Op`) and by ACP memo signing in `raxol_earn`.

  ## Example

      domain = %{
        name: "USD Coin",
        version: "2",
        chainId: 8453,
        verifyingContract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      }

      types = %{
        "TransferWithAuthorization" => [
          {"from", "address"},
          {"to", "address"},
          {"value", "uint256"},
          {"validAfter", "uint256"},
          {"validBefore", "uint256"},
          {"nonce", "bytes32"}
        ]
      }

      message = %{
        from: "0xabc...",
        to: "0xdef...",
        value: 1_000_000,
        validAfter: 0,
        validBefore: 9_999_999_999,
        nonce: "0x" <> String.duplicate("00", 32)
      }

      {:ok, digest} = Raxol.Payments.EIP712.hash(domain, types, message)
  """

  @max_uint256 Integer.pow(2, 256) - 1

  @doc """
  Hash an EIP-712 typed message into a 32-byte digest.

  - `domain` — EIP-712 domain separator fields. Recognized keys: `:name`,
    `:version`, `:chainId` (or `:chain_id`), `:verifyingContract` (or
    `:verifying_contract`), and `:salt` (bytes32). Only the keys present in
    the map are included in the domain type, matching reference implementations.
  - `types` — map of struct type names to field definitions. The primary type
    is the one type no other type references; a map with no such type (a
    cycle) or with several is refused rather than guessed.
  - `message` — map of field values for the primary type.

  Returns `{:ok, digest}` on success or `{:error, reason}` if a value
  cannot be encoded under its declared type.

  A caller signing typed data it did not build should use `hash/4` with the
  primary type it expects, so the struct that gets hashed is not chosen by the
  served `types` map.
  """
  @spec hash(map(), map(), map()) :: {:ok, binary()} | {:error, term()}
  def hash(domain, types, message) do
    case primary_type(types) do
      nil -> {:error, :no_primary_type}
      primary -> hash(domain, primary, types, message)
    end
  end

  @doc """
  Hash `message` as the struct `primary_type` of `types`, under `domain`.

  The root is the caller's, not the map's: `{:error, {:unknown_primary_type,
  name}}` when `types` does not define it.
  """
  @spec hash(map(), String.t(), map(), map()) :: {:ok, binary()} | {:error, term()}
  def hash(domain, primary_type, types, message)
      when is_binary(primary_type) and is_map(types) do
    if Map.has_key?(types, primary_type) do
      with {:ok, domain_separator} <-
             hash_struct("EIP712Domain", domain, eip712_domain_types(domain)),
           {:ok, message_hash} <- hash_struct(primary_type, message, types) do
        {:ok, ExKeccak.hash_256(<<0x19, 0x01, domain_separator::binary, message_hash::binary>>)}
      end
    else
      {:error, {:unknown_primary_type, primary_type}}
    end
  end

  @doc """
  The EIP-712 `typeHash` of `type_name` in `types`: `keccak256(encodeType)`,
  with the referenced struct types appended in name order.
  """
  @spec type_hash(String.t(), map()) :: binary()
  def type_hash(type_name, types) when is_binary(type_name) and is_map(types),
    do: encode_type(type_name, types)

  @doc """
  Hash a typed message against a domain separator obtained from somewhere other
  than the `domain` map -- in practice the verifying contract's own
  `DOMAIN_SEPARATOR()`, read from chain.

  `hash/3` builds the separator from the fields present in `domain`, so a caller
  checking our own signature with it asks the verifier about the very digest we
  computed, and any disagreement over which fields the domain has cancels out on
  both sides. Supplying the counterparty's separator removes that: the domain
  half of the digest comes from the contract that will verify it, so a projection
  that drops or invents a field is visible rather than self-consistent: a
  `version` field we added to a Permit2 domain, which Permit2 never declares,
  reverted the origin pull.

  The struct half is still encoded here, and is covered against ethers-generated
  vectors by the Permit2 and ERC-3009 conformance suites.
  """
  @spec hash_with_separator(term(), map(), map()) :: {:ok, binary()} | {:error, term()}
  def hash_with_separator(<<domain_separator::binary-size(32)>>, types, message) do
    with primary when is_binary(primary) <- primary_type(types),
         {:ok, message_hash} <- hash_struct(primary, message, types) do
      {:ok, ExKeccak.hash_256(<<0x19, 0x01, domain_separator::binary, message_hash::binary>>)}
    else
      nil -> {:error, :no_primary_type}
      {:error, _} = err -> err
    end
  end

  def hash_with_separator(separator, _types, _message) when is_binary(separator) do
    {:error, {:invalid_domain_separator_length, byte_size(separator)}}
  end

  # The separator reaching this comes off the wire (an `eth_call` result a caller
  # decoded), so a non-binary is a shape this function is asked about rather than
  # a caller bug. Returning the error the spec already promises beats raising a
  # FunctionClauseError out of a public function.
  def hash_with_separator(separator, _types, _message) do
    {:error, {:invalid_domain_separator, separator}}
  end

  @doc """
  Pack an `ExSecp256k1.sign/2` result into Ethereum's canonical 65-byte
  signature `r || s || v`.

  `ExSecp256k1.sign/2` returns the recovery id as `0` or `1`. Ethereum's
  `ecrecover` -- and the ERC-3009 / Permit2 on-chain authorizations the Xochi
  origin pull and x402 settlement are verified against -- require the canonical
  `27` / `28`, returning `address(0)` for `v < 27`. Normalizing here keeps every
  wallet's output verifiable both on-chain and off-chain (viem accepts either
  form). Idempotent: a signature already carrying `27` / `28` is unchanged.
  """
  @spec pack_signature({binary(), binary(), 0..28}) :: binary()
  def pack_signature({<<r::binary-size(32)>>, <<s::binary-size(32)>>, v})
      when is_integer(v) do
    <<r::binary-size(32), s::binary-size(32), canonical_v(v)::8>>
  end

  @doc """
  Derive the `0x`-prefixed, lowercase Ethereum address from a 65-byte
  uncompressed secp256k1 public key (`0x04 || X || Y`): the last 20 bytes of
  `keccak256(X || Y)`.
  """
  @spec address_from_pubkey(<<_::520>>) :: String.t()
  def address_from_pubkey(<<_prefix::8, xy::binary-size(64)>>) do
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  @doc """
  Whether `value` is an EVM address in clean form: `0x` (or `0X`) and exactly
  40 hex digits, with no surrounding whitespace. A mixed-case body must carry a
  valid EIP-55 checksum; an all-lowercase or all-uppercase body carries none.

  `checksum: false` checks the shape only. Use it for addresses another party
  serves, which are compared case-insensitively, and keep the checksum for
  values an operator types (pins, allowlists), where it catches a typo.
  """
  @spec address?(term(), keyword()) :: boolean()
  def address?(value, opts \\ [])

  def address?(<<prefix::binary-size(2), hex::binary-size(40)>>, opts)
      when prefix in ["0x", "0X"] do
    Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, hex) and
      (Keyword.get(opts, :checksum, true) == false or checksum_ok?(hex))
  end

  def address?(_value, _opts), do: false

  defp checksum_ok?(hex) do
    lower = String.downcase(hex)

    if hex == lower or hex == String.upcase(hex),
      do: true,
      else: hex == to_checksum_case(lower)
  end

  # EIP-55: uppercase each letter whose nibble in keccak256(lowercase hex) is >= 8.
  defp to_checksum_case(lower) do
    nibbles = for <<n::4 <- ExKeccak.hash_256(lower)>>, do: n

    lower
    |> String.graphemes()
    |> Enum.zip(nibbles)
    |> Enum.map_join(fn {char, n} -> if n >= 8, do: String.upcase(char), else: char end)
  end

  @doc """
  Canonicalize an EVM address for comparison: trim, downcase, and strip a
  leading `0x`. Returns the lowercase hex body (no `0x`).
  """
  @spec normalize_address(binary()) :: binary()
  def normalize_address(addr) when is_binary(addr) do
    addr
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("0x", "")
  end

  defp canonical_v(v) when v in [0, 1], do: v + 27
  defp canonical_v(v) when v in [27, 28], do: v

  # A secp256k1 recovery id is 0/1 (or the 27/28 Ethereum form). Anything else
  # (an EIP-155 chain-encoded v, or a buggy signer) would silently pack a
  # non-recovering signature, so fail loud rather than emit one.
  defp canonical_v(v),
    do: raise(ArgumentError, "non-canonical secp256k1 recovery id: #{inspect(v)}")

  # EIP-712 defines exactly five domain fields, in this order: name, version,
  # chainId, verifyingContract, salt. Only the keys present in the domain map are
  # emitted, matching reference implementations. `salt` (bytes32) is required by
  # contracts that domain-separate without a verifyingContract -- the Xochi
  # XochiIntent domain is keyed by name/version/chainId/salt, so omitting it
  # hashes a 3-field separator against the worker's 4-field one and the signature
  # cannot recover.
  defp eip712_domain_types(domain) do
    fields =
      [
        if(Map.has_key?(domain, :name), do: {"name", "string"}),
        if(Map.has_key?(domain, :version), do: {"version", "string"}),
        if(Map.has_key?(domain, :chainId) || Map.has_key?(domain, :chain_id),
          do: {"chainId", "uint256"}
        ),
        if(
          Map.has_key?(domain, :verifyingContract) ||
            Map.has_key?(domain, :verifying_contract),
          do: {"verifyingContract", "address"}
        ),
        if(Map.has_key?(domain, :salt), do: {"salt", "bytes32"})
      ]
      |> Enum.reject(&is_nil/1)

    %{"EIP712Domain" => fields}
  end

  # EIP-712 primary type detection: the primary is the unique type that
  # is NOT referenced as a field type by any other type in the map.
  # For a single-struct types map, that's just the only key. For nested
  # structs (e.g. Permit2 PermitWitnessTransferFrom referencing
  # TokenPermissions and OriginPullWitness), this picks the outer type
  # deterministically regardless of Elixir map iteration order.
  @doc false
  # Public for `Raxol.Payments.DeliveryFloor`, which must read a signed field
  # from the same struct the encoder hashes.
  @spec primary_type(map()) :: String.t() | nil
  def primary_type(types) do
    all_names = MapSet.new(Map.keys(types))

    referenced =
      types
      |> Map.values()
      |> Enum.flat_map(fn fields ->
        Enum.map(fields, fn {_name, type} -> base_type(type) end)
      end)
      |> MapSet.new()

    candidates = MapSet.difference(all_names, referenced)

    case MapSet.to_list(candidates) do
      [primary] ->
        primary

      # No root (a cycle) or several roots: there is no primary type to hash,
      # and guessing one lets the map choose the struct that gets signed.
      _none_or_several ->
        nil
    end
  end

  # EIP-712: hashStruct(s) = keccak256(typeHash || encodeData(s))
  # where typeHash = keccak256(encodeType(s)) and encodeType returns the string.
  defp hash_struct(type_name, data, types) do
    type_hash = encode_type(type_name, types)

    case encode_data(type_name, data, types) do
      {:error, _} = err ->
        err

      encoded_data ->
        {:ok, ExKeccak.hash_256(<<type_hash::binary, encoded_data::binary>>)}
    end
  end

  # EIP-712: encodeType(s) = enc(s) ++ enc(t_1) ++ ... ++ enc(t_n)
  # where t_i are struct types referenced (transitively) by s, sorted
  # alphabetically by name and deduplicated. Without the referenced types
  # appended, nested structs like Permit2 PermitWitnessTransferFrom produce
  # a typeHash ethers v5 won't match.
  defp encode_type(type_name, types) do
    primary = type_string(type_name, types)

    referenced =
      type_name
      |> collect_referenced_types(types, MapSet.new())
      |> MapSet.delete(type_name)
      |> Enum.sort()
      |> Enum.map_join("", &type_string(&1, types))

    ExKeccak.hash_256(primary <> referenced)
  end

  defp type_string(type_name, types) do
    fields = Map.get(types, type_name, [])

    type_name <>
      "(" <>
      Enum.map_join(fields, ",", fn {name, type} -> "#{type} #{name}" end) <>
      ")"
  end

  defp collect_referenced_types(type_name, types, seen) do
    if MapSet.member?(seen, type_name) do
      seen
    else
      seen = MapSet.put(seen, type_name)
      fields = Map.get(types, type_name, [])

      Enum.reduce(fields, seen, fn {_name, type}, acc ->
        collect_struct_type(base_type(type), types, acc)
      end)
    end
  end

  # Only struct types recurse; a primitive base type adds nothing.
  defp collect_struct_type(base, types, seen) do
    if Map.has_key?(types, base),
      do: collect_referenced_types(base, types, seen),
      else: seen
  end

  defp base_type(type) when is_binary(type) do
    case String.split(type, "[", parts: 2) do
      [base, _] -> base
      [base] -> base
    end
  end

  # A struct value that is not a map (a served nested struct or array element
  # of the wrong shape) is refused like any other value of the wrong type.
  defp encode_data(type_name, data, _types) when not is_map(data),
    do: {:error, {:invalid_value, type_name}}

  defp encode_data(type_name, data, types) do
    fields = Map.get(types, type_name, [])

    fields
    |> Enum.reduce_while(<<>>, fn {name, type}, acc ->
      case encode_value(type, field_value(data, name), types) do
        {:ok, encoded} -> {:cont, <<acc::binary, encoded::binary>>}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # `false` is a value, not a missing key: a served `false` for a uint256 is
  # refused rather than read as absent and encoded as zero.
  defp field_value(data, name) do
    case Map.fetch(data, name) do
      {:ok, value} -> value
      :error -> safe_atom_get(data, name)
    end
  end

  # Look up a string key as an existing atom. Returns nil if the atom
  # doesn't exist, avoiding atom table exhaustion from external input.
  defp safe_atom_get(data, name) do
    Map.get(data, String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  # Nested struct field: hashStruct(value) becomes the 32-byte encoded
  # value at this slot. Required for Permit2 PermitWitnessTransferFrom
  # (`TokenPermissions permitted`, `OriginPullWitness witness`) and any
  # other EIP-712 type that references another struct.
  defp encode_value(type, value, types)
       when is_binary(type) and is_map(value) do
    if Map.has_key?(types, type) do
      hash_struct(type, value, types)
    else
      # A map value whose type is not a declared struct is a malformed type
      # definition. `encode_value/2` has no map clause, so surface a clean error
      # rather than crashing with FunctionClauseError.
      {:error, {:unknown_struct_type, type}}
    end
  end

  # Array of structs: each element is hashed via hash_struct/3, the
  # resulting 32-byte hashes are concatenated, and the concatenation is
  # hashed once more (EIP-712 dynamic array rule).
  defp encode_value(type, value, types)
       when is_binary(type) and is_list(value) do
    case array_element_type(type) do
      {:ok, element_type} when is_map_key(types, element_type) ->
        encode_struct_array(element_type, value, types)

      _primitive_array_or_not_an_array ->
        encode_value(type, value)
    end
  end

  # Delegate everything else to the existing arity-2 implementation. The
  # arity-3 entry point exists only to thread `types` through for the
  # nested-struct cases above.
  defp encode_value(type, value, _types), do: encode_value(type, value)

  defp encode_struct_array(element_type, values, types) do
    Enum.reduce_while(values, {:ok, <<>>}, fn v, {:ok, acc} ->
      case hash_struct(element_type, v, types) do
        {:ok, h} -> {:cont, {:ok, <<acc::binary, h::binary>>}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, concatenated} -> {:ok, ExKeccak.hash_256(concatenated)}
      err -> err
    end
  end

  defp encode_value("address", value) when is_binary(value) do
    hex = String.trim_leading(value, "0x")

    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 ->
        {:ok, pad_left(bytes, 32)}

      {:ok, bytes} ->
        {:error, {:invalid_address_length, byte_size(bytes)}}

      :error ->
        {:error, {:invalid_hex, "address"}}
    end
  end

  # A value outside 0..2^256-1 is refused: `<<v::unsigned-big-256>>` would keep
  # the low 256 bits, so 2^256 + 1 signed as 1 and -1 as 2^256 - 1.
  defp encode_value("uint256", value) when is_integer(value) do
    if value in 0..@max_uint256,
      do: {:ok, <<value::unsigned-big-256>>},
      else: {:error, {:invalid_uint256, value}}
  end

  # 2^256 - 1 has 78 decimal digits. A longer string is refused before
  # `Integer.parse`, which would otherwise spend unbounded time on (or raise
  # `SystemLimitError` for) a multi-megabyte digit string.
  defp encode_value("uint256", value) when is_binary(value) and byte_size(value) > 78,
    do: {:error, {:invalid_uint256, value}}

  defp encode_value("uint256", value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in 0..@max_uint256 -> {:ok, <<int::unsigned-big-256>>}
      _ -> {:error, {:invalid_uint256, value}}
    end
  end

  defp encode_value("bytes32", value) when is_binary(value) do
    hex = String.trim_leading(value, "0x")

    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, pad_right(bytes, 32)}
      :error -> {:error, {:invalid_hex, "bytes32"}}
    end
  end

  defp encode_value("string", value) when is_binary(value) do
    {:ok, ExKeccak.hash_256(value)}
  end

  defp encode_value("bool", true), do: {:ok, <<1::unsigned-big-256>>}
  defp encode_value("bool", false), do: {:ok, <<0::unsigned-big-256>>}

  # EIP-712 dynamic array: encodeData(T[]) = keccak256(concat(encodeData(T)_i)).
  # For a `string[]` field, each element gets `keccak256(s_i)` first (the
  # `encode_value("string", _)` clause above), then those 32-byte hashes
  # are concatenated and hashed again. The same recursion handles
  # `address[]`, `uint256[]`, `bytes32[]`, and `bool[]` correctly.
  defp encode_value(type, value) when is_binary(type) and is_list(value) do
    case array_element_type(type) do
      {:ok, element_type} -> encode_array(element_type, value)
      :error -> {:error, {:list_for_scalar_type, type}}
    end
  end

  defp encode_value(_type, nil), do: {:ok, <<0::unsigned-big-256>>}

  defp encode_value(_type, value) when is_binary(value) do
    {:ok, pad_left(value, 32)}
  end

  # Any other value (a float, a boolean for a non-bool type, an integer for a
  # bytes32 or address, a map for a scalar) is refused. The value itself stays
  # out of the error: it is served data.
  defp encode_value(type, _value), do: {:error, {:invalid_value, type}}

  defp array_element_type(type) do
    case String.split(type, "[]", parts: 2) do
      [element_type, ""] when element_type != "" -> {:ok, element_type}
      _ -> :error
    end
  end

  defp encode_array(element_type, values) do
    Enum.reduce_while(values, {:ok, <<>>}, fn v, {:ok, acc} ->
      case encode_value(element_type, v) do
        {:ok, encoded} -> {:cont, {:ok, <<acc::binary, encoded::binary>>}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, concatenated} -> {:ok, ExKeccak.hash_256(concatenated)}
      err -> err
    end
  end

  defp pad_left(bytes, size) do
    padding = size - byte_size(bytes)

    if padding > 0 do
      <<0::size(padding * 8), bytes::binary>>
    else
      binary_part(bytes, byte_size(bytes) - size, size)
    end
  end

  defp pad_right(bytes, size) do
    padding = size - byte_size(bytes)

    if padding > 0 do
      <<bytes::binary, 0::size(padding * 8)>>
    else
      binary_part(bytes, 0, size)
    end
  end
end

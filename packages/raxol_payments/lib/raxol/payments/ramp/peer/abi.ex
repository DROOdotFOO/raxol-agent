defmodule Raxol.Payments.Ramp.Peer.ABI do
  @moduledoc "Bounded ABI codec for the pinned Peer contract subset; no RPC or signing."
  @config_path Path.expand("../../../../../priv/ramp/peer_contracts.json", __DIR__)
  @external_resource @config_path
  @config @config_path |> File.read!() |> Jason.decode!()
  def config, do: @config
  def address(name), do: String.downcase(@config["addresses"][name])
  def function(contract, name), do: Enum.find(@config["abi"][contract], &(&1["name"] == name))
  def hash(data), do: "0x" <> Base.encode16(ExKeccak.hash_256(data), case: :lower)
  def unhex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  def hex(data), do: "0x" <> Base.encode16(data, case: :lower)

  def call(contract, name, args) do
    spec = function(contract, name)
    signature = name <> "(" <> Enum.map_join(spec["inputs"], ",", &type_name/1) <> ")"
    <<selector::binary-size(4), _::binary>> = ExKeccak.hash_256(signature)
    hex(selector <> encode(spec["inputs"], args))
  end

  def result(contract, name, hex) do
    data = unhex(hex)
    true = byte_size(data) <= 262_144
    outputs = function(contract, name)["outputs"]

    case decode(outputs, data) do
      [single] -> single
      values -> Map.new(Enum.zip(Enum.map(outputs, & &1["name"]), values))
    end
  end

  def type_name(%{"type" => "tuple" <> suffix} = spec),
    do: "(" <> Enum.map_join(spec["components"], ",", &type_name/1) <> ")" <> suffix

  def type_name(spec), do: spec["type"]

  def encode(specs, values) when length(specs) == length(values) do
    size = Enum.sum(Enum.map(specs, &head_size/1))

    {heads, tails, _} =
      Enum.zip(specs, values)
      |> Enum.reduce({[], [], size}, fn {spec, value}, {hs, ts, offset} ->
        encoded = encode_one(spec, value)

        if dynamic?(spec),
          do: {[hs, word(offset)], [ts, encoded], offset + byte_size(encoded)},
          else: {[hs, encoded], ts, offset}
      end)

    IO.iodata_to_binary([heads, tails])
  end

  def decode(specs, data) do
    {values, _} =
      Enum.map_reduce(specs, 0, fn spec, offset ->
        pos = if dynamic?(spec), do: uint_at(data, offset), else: offset
        {decode_one(spec, data, pos), offset + head_size(spec)}
      end)

    values
  end

  defp dynamic?(%{"type" => type} = spec) do
    cond do
      String.ends_with?(type, "[]") -> true
      type == "bytes" -> true
      type == "tuple" -> Enum.any?(spec["components"], &dynamic?/1)
      true -> false
    end
  end

  defp head_size(spec), do: if(dynamic?(spec), do: 32, else: static_size(spec))

  defp static_size(%{"type" => "tuple", "components" => cs}),
    do: Enum.sum(Enum.map(cs, &head_size/1))

  defp static_size(_), do: 32
  defp element(spec), do: Map.update!(spec, "type", &String.slice(&1, 0, byte_size(&1) - 2))

  defp word(n)
       when n >= 0 and n < 0x10000000000000000000000000000000000000000000000000000000000000000,
       do: <<n::unsigned-big-256>>

  defp encode_one(%{"type" => "address"}, value), do: <<0::96>> <> sized_hex(value, 20)
  defp encode_one(%{"type" => "bytes32"}, value), do: sized_hex(value, 32)

  defp encode_one(%{"type" => "bool"}, value) when is_boolean(value),
    do: word(if(value, do: 1, else: 0))

  defp encode_one(%{"type" => type} = spec, value) do
    cond do
      String.ends_with?(type, "[]") ->
        word(length(value)) <> encode(List.duplicate(element(spec), length(value)), value)

      type == "tuple" ->
        encode(spec["components"], Enum.map(spec["components"], &Map.fetch!(value, &1["name"])))

      type == "bytes" ->
        encode_bytes(unhex(value))

      String.starts_with?(type, "uint") ->
        true = value >= 0 and value < Integer.pow(2, bits(type, "uint"))
        word(value)

      String.starts_with?(type, "int") ->
        limit = Integer.pow(2, bits(type, "int") - 1)
        true = value >= -limit and value < limit
        <<value::signed-big-256>>
    end
  end

  defp bits(type, prefix), do: type |> String.replace_prefix(prefix, "") |> String.to_integer()

  defp encode_bytes(bytes) do
    word(byte_size(bytes)) <>
      bytes <> :binary.copy(<<0>>, rem(32 - rem(byte_size(bytes), 32), 32))
  end

  defp sized_hex(hex, size) do
    bytes = unhex(hex)
    ^size = byte_size(bytes)
    bytes
  end

  defp decode_one(%{"type" => "bool"}, data, pos), do: decode_bool(uint_at(data, pos))

  defp decode_one(%{"type" => type} = spec, data, pos) do
    cond do
      String.ends_with?(type, "[]") ->
        count = uint_at(data, pos)
        true = count <= 1000
        decode(List.duplicate(element(spec), count), slice(data, pos + 32))

      type == "tuple" ->
        values = decode(spec["components"], slice(data, pos))
        Map.new(Enum.zip(Enum.map(spec["components"], & &1["name"]), values))

      type == "bytes" ->
        hex(binary_part(data, pos + 32, uint_at(data, pos)))

      type == "address" ->
        <<0::96>> = binary_part(data, pos, 12)
        hex(binary_part(data, pos + 12, 20))

      type == "bytes32" ->
        hex(binary_part(data, pos, 32))

      String.starts_with?(type, "uint") ->
        n = uint_at(data, pos)
        true = n < Integer.pow(2, bits(type, "uint"))
        n

      String.starts_with?(type, "int") ->
        <<n::signed-big-256>> = binary_part(data, pos, 32)
        limit = Integer.pow(2, bits(type, "int") - 1)
        true = n >= -limit and n < limit
        n
    end
  end

  defp decode_bool(0), do: false
  defp decode_bool(1), do: true
  defp uint_at(data, pos), do: :binary.decode_unsigned(binary_part(data, pos, 32))
  defp slice(data, pos), do: binary_part(data, pos, byte_size(data) - pos)
end

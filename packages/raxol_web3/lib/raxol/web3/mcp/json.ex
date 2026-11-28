defmodule Raxol.Web3.MCP.JSON do
  @moduledoc """
  The JSON text a served tool returns.

  `Raxol.MCP.Server` renders a callback's `{:ok, binary}` as that binary and
  anything else with `inspect/2`, so a map handed back as-is reached every
  client as Elixir term syntax (`%{unit: :block, height: 26510414}`). The
  tools in `Raxol.Web3.MCP.Tools` therefore return text, and this module is
  where the text is made.

  ## The shape

  `Raxol.Web3.Serialize.result/1` runs first, so tagged references are
  `"tag:value"`, timestamps are ISO 8601 and decimals are strings. Then:

    * Keys are strings, spelled exactly as the backend contract's atom keys
      (`"contract?"`, `"finalized_height"`), so a key is the same in every
      result of every tool.
    * Atoms other than `nil`, `true` and `false` are strings: `:block` is
      `"block"`.
    * An amount is a decimal string whatever its size. `balance`, `value`,
      `fee` and `amount` are the four integer amount fields in
      `Raxol.Web3.Backend`'s types, and they are counted in the chain's
      smallest unit, so a wei balance passes 2^53 at about 0.009 ETH. Writing
      only the large ones as strings would give one field two JSON types, and
      a client's parser would work on a test wallet and fail on a real one.
    * Any other integer outside +/-(2^53 - 1) is a decimal string, so no
      client that reads JSON numbers as IEEE doubles loses digits. Heights and
      counts are far below that bound and stay numbers.

  The rules match only atom keys, which is what the normalized contract uses.
  String keys come from upstream JSON passed through whole (a contract's ABI),
  and their values are left as the upstream wrote them.
  """

  alias Raxol.Web3.Serialize

  @max_safe_integer 9_007_199_254_740_991
  @amount_keys [:balance, :value, :fee, :amount]

  @doc "Encode a read result as JSON text."
  @spec encode(term()) :: {:ok, String.t()} | {:error, :unencodable_result}
  def encode(value) do
    case value |> Serialize.result() |> safe() |> Jason.encode() do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :unencodable_result}
    end
  end

  @doc """
  A term as JSON-safe data: string keys, string atoms, and integers that a
  double cannot hold as strings. `encode/1` is this plus `Jason`.
  """
  @spec safe(term()) :: term()
  def safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {key(key), field(key, value)} end)
  end

  def safe(list) when is_list(list), do: Enum.map(list, &safe/1)
  def safe(value) when value in [nil, true, false], do: value
  def safe(atom) when is_atom(atom), do: Atom.to_string(atom)

  def safe(integer) when is_integer(integer) and abs(integer) > @max_safe_integer,
    do: Integer.to_string(integer)

  def safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> safe()
  def safe(value), do: value

  defp field(key, amount) when key in @amount_keys and is_integer(amount),
    do: Integer.to_string(amount)

  defp field(_key, value), do: safe(value)

  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key) when is_integer(key), do: Integer.to_string(key)
  # Anything else is left for `Jason` to refuse, which `encode/1` reports.
  defp key(key), do: key
end

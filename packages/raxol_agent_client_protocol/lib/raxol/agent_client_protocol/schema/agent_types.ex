defmodule Raxol.AgentClientProtocol.Schema.AgentTypes do
  @moduledoc """
  Agent-side ACP types (`initialize`, `authenticate`, `session/*`, capabilities,
  MCP server descriptors) and the decode/encode helpers shared by the schema
  modules.

  Every struct carries a `_meta` map: unknown top-level wire keys and the
  contents of an explicit `"_meta"` object are folded into it on decode and
  re-emitted under `"_meta"` on encode, so round trips never lose data.
  `from_json/1` never raises. Load-bearing string fields (`cwd`, `sessionId`,
  `modeId`, `methodId`) are type-checked, so a wrong-typed value fails decode
  with `{:invalid_field, key, value}` (JSON-RPC `-32602`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type decoder :: (term() -> {:ok, term()} | {:error, term()})

  @doc false
  @spec fetch(map(), String.t()) ::
          {:ok, term()} | {:error, {:missing_field, String.t()}}
  def fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @doc false
  @spec fetch(map(), String.t(), (term() -> boolean())) ::
          {:ok, term()}
          | {:error, {:missing_field, String.t()} | {:invalid_field, String.t(), term()}}
  def fetch(map, key, valid?) when is_map(map) and is_function(valid?, 1) do
    with {:ok, value} <- fetch(map, key) do
      if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key, value}}
    end
  end

  @doc false
  # Strict: the first item that fails aborts the whole list.
  @spec decode_list(term(), decoder()) :: {:ok, [term()]} | {:error, term()}
  def decode_list(list, decoder) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case decoder.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def decode_list(_not_a_list, _decoder), do: {:error, :not_a_list}

  @doc false
  @spec decode_optional(map(), String.t(), decoder()) :: {:ok, term() | nil} | {:error, term()}
  def decode_optional(map, key, decoder) when is_map(map) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> decoder.(value)
    end
  end

  @doc false
  # Only a literal boolean survives; anything else (`0`, `"false"`, ...) reads
  # as `false`, so a malformed capability is never coerced to advertised.
  @spec decode_bool(map(), String.t()) :: boolean()
  def decode_bool(map, key) when is_map(map), do: Map.get(map, key) == true

  @doc false
  @spec extract_meta(map(), [String.t()]) :: map()
  def extract_meta(map, known_keys) when is_map(map) do
    map
    |> Map.drop(["_meta" | known_keys])
    |> Map.merge(meta_of(map))
  end

  defp meta_of(%{"_meta" => meta}) when is_map(meta), do: meta
  defp meta_of(_map), do: %{}

  @doc "Puts a non-empty `_meta` bucket under the wire `\"_meta\"` key."
  @spec put_meta(map(), map()) :: map()
  def put_meta(json, meta) when map_size(meta) == 0, do: json
  def put_meta(json, meta) when is_map(meta), do: Map.put(json, "_meta", meta)

  @doc false
  @spec maybe_put(map(), String.t(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec put_encoded(map(), String.t(), term(), (term() -> term())) :: map()
  def put_encoded(map, _key, nil, _encode), do: map
  def put_encoded(map, key, value, encode), do: Map.put(map, key, encode.(value))
end

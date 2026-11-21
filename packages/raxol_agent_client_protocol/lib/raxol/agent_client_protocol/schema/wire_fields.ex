defmodule Raxol.AgentClientProtocol.Schema.WireFields do
  @moduledoc false
  # Decode/encode helpers for Content, Plan, ToolCall and friends. Optional
  # fields fall back to absent on a decode error and invalid list items are
  # skipped (the schema's `x-deserialize-default-on-error` and
  # `x-deserialize-skip-invalid-items`); required fields fail the object.

  @doc """
  Split a raw wire map into its `_meta` bucket: the wire object's own
  `"_meta"` map (if any) merged with any top-level field the caller didn't
  recognize (`known_keys`). Nothing is ever silently dropped; re-emit via
  `emit_meta/2` on encode.
  """
  @spec fold_meta(map(), [String.t()]) :: map()
  def fold_meta(map, known_keys) when is_map(map) and is_list(known_keys) do
    extras = map |> Map.drop(known_keys) |> Map.drop(["_meta"])
    Map.merge(meta_of(map), extras)
  end

  defp meta_of(%{"_meta" => meta}) when is_map(meta), do: meta
  defp meta_of(_map), do: %{}

  @doc "Re-emit a struct's `_meta` bucket under the wire `\"_meta\"` key, omitted when empty."
  @spec emit_meta(map(), map()) :: map()
  def emit_meta(json, meta) when map_size(meta) == 0, do: json
  def emit_meta(json, meta) when is_map(meta), do: Map.put(json, "_meta", meta)

  @doc "Put `key => value` unless `value` is `nil` (nil fields are omitted, never emitted as `null`)."
  @spec put(map(), String.t(), term()) :: map()
  def put(json, _key, nil), do: json
  def put(json, key, value), do: Map.put(json, key, value)

  @doc """
  Fetch a required field. A missing key, or a present value failing
  `valid?`, returns a descriptive `{:error, _}` instead of raising -- the
  caller's `from_json` propagates this via `with`, failing the whole object.
  """
  @spec require(map(), String.t(), (term() -> boolean())) ::
          {:ok, term()}
          | {:error, {:missing_field, String.t()} | {:invalid_field, String.t(), term()}}
  def require(map, key, valid?) do
    case Map.fetch(map, key) do
      :error -> {:error, {:missing_field, key}}
      {:ok, value} -> require_valid(key, value, valid?)
    end
  end

  defp require_valid(key, value, valid?) do
    if valid?.(value) do
      {:ok, value}
    else
      {:error, {:invalid_field, key, value}}
    end
  end

  @doc """
  Fetch an optional field, defaulting to `nil` when the key is absent or the
  value fails `valid?` (the "default on error" leniency the official schema
  documents for optional scalar fields).
  """
  @spec optional(map(), String.t(), (term() -> boolean())) :: term() | nil
  def optional(map, key, valid?) do
    case Map.get(map, key) do
      nil -> nil
      value -> optional_valid(value, valid?)
    end
  end

  defp optional_valid(value, valid?) do
    if valid?.(value), do: value, else: nil
  end

  @doc """
  Fetch and decode an optional nested object, defaulting to `nil` when the
  key is absent or `decoder` returns `{:error, _}` (same "default on error"
  leniency, for fields whose value is itself another ACP schema object).
  """
  @spec optional_nested(map(), String.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          term() | nil
  def optional_nested(map, key, decoder) do
    case Map.get(map, key) do
      nil -> nil
      value -> unwrap_or_nil(decoder.(value))
    end
  end

  defp unwrap_or_nil({:ok, value}), do: value
  defp unwrap_or_nil({:error, _reason}), do: nil

  @doc """
  Decode a wire array leniently: items that fail `decoder` are skipped
  rather than aborting the whole list, and a missing/non-list value falls
  back to `default` (matches the schema's combined
  `x-deserialize-default-on-error` + `x-deserialize-skip-invalid-items`).
  """
  @spec list_lenient(term(), (term() -> {:ok, term()} | {:error, term()}), term()) :: term()
  def list_lenient(list, decoder, _default) when is_list(list) do
    Enum.flat_map(list, fn item ->
      case decoder.(item) do
        {:ok, value} -> [value]
        {:error, _reason} -> []
      end
    end)
  end

  def list_lenient(_not_a_list, _decoder, default), do: default
end

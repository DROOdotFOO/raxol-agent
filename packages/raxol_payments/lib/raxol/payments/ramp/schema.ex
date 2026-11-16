defmodule Raxol.Payments.Ramp.Schema do
  @moduledoc false
  # Implements the vocabulary used by the pinned canonical schema. Unknown
  # optional keys are stripped; strict command/intent objects reject them.
  @schema File.read!(Path.expand("../../../../priv/ramp/contract.schema.json", __DIR__))
          |> Jason.decode!()
  @external_resource Path.expand("../../../../priv/ramp/contract.schema.json", __DIR__)

  def parse(value), do: validate(value, @schema)

  def bounded?(value) do
    case bound(value, 0, 2048) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp bound(_, depth, budget) when depth > 16 or budget < 1, do: :error
  defp bound(v, _, budget) when is_boolean(v) or is_nil(v), do: {:ok, budget - 1}

  defp bound(v, _, budget) when is_integer(v) and abs(v) <= 9_007_199_254_740_991,
    do: {:ok, budget - 1}

  defp bound(v, _, budget) when is_binary(v) do
    if json_length(v) <= 2048, do: {:ok, budget - 1}, else: :error
  end

  defp bound(v, depth, budget) when is_list(v) and length(v) <= 128,
    do: bound_items(v, depth, budget)

  defp bound(v, depth, budget) when is_map(v) and not is_struct(v) and map_size(v) <= 64 do
    if Enum.all?(Map.keys(v), &(is_binary(&1) and json_length(&1) <= 64)),
      do: bound_items(Map.values(v), depth, budget),
      else: :error
  end

  defp bound(_, _, _), do: :error

  defp bound_items(items, depth, budget) do
    Enum.reduce_while(items, {:ok, budget - 1}, fn item, {:ok, left} ->
      case bound(item, depth + 1, left) do
        {:ok, remaining} -> {:cont, {:ok, remaining}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp validate(v, %{"oneOf" => schemas}), do: alternatives(v, schemas)
  defp validate(v, %{"anyOf" => schemas}), do: alternatives(v, schemas)

  defp validate(v, %{"type" => "object"} = s) when is_map(v) do
    props = s["properties"] || %{}
    keys = Map.keys(v)

    if Enum.all?(s["required"] || [], &Map.has_key?(v, &1)) and
         (s["additionalProperties"] != false or Enum.all?(keys, &Map.has_key?(props, &1))) do
      Enum.reduce_while(props, {:ok, %{}}, &property(&1, &2, v))
    else
      :error
    end
  end

  defp validate(v, %{"type" => "array"} = s) when is_list(v) do
    if length(v) >= Map.get(s, "minItems", 0) and length(v) <= Map.get(s, "maxItems", 128) do
      v |> Enum.with_index() |> Enum.reduce_while({:ok, []}, &item(&1, &2, s))
    else
      :error
    end
  end

  defp validate(v, %{"type" => "string"} = s) when is_binary(v) do
    valid = literal?(v, s) and length?(v, s) and pattern?(v, s)

    if valid, do: {:ok, v}, else: :error
  end

  defp validate(v, %{"type" => "integer"} = s) when is_integer(v) do
    if v >= Map.get(s, "minimum", v) and v <= Map.get(s, "maximum", v),
      do: {:ok, v},
      else: :error
  end

  defp validate(v, %{"type" => "boolean"}) when is_boolean(v), do: {:ok, v}
  defp validate(_, _), do: :error

  defp property({key, schema}, {:ok, acc}, value) do
    case Map.fetch(value, key) do
      :error -> {:cont, {:ok, acc}}
      {:ok, item} -> put_validated(item, schema, acc, key)
    end
  end

  defp put_validated(item, schema, acc, key) do
    case validate(item, schema) do
      {:ok, clean} -> {:cont, {:ok, Map.put(acc, key, clean)}}
      _ -> {:halt, :error}
    end
  end

  defp item({item, index}, {:ok, acc}, s) do
    schema = if is_list(s["items"]), do: Enum.at(s["items"], index), else: s["items"]

    case validate(item, schema || %{}) do
      {:ok, clean} -> {:cont, {:ok, acc ++ [clean]}}
      _ -> {:halt, :error}
    end
  end

  defp literal?(v, s),
    do:
      (not Map.has_key?(s, "const") or v == s["const"]) and
        (not Map.has_key?(s, "enum") or v in s["enum"])

  defp length?(v, s),
    do:
      json_length(v) >= Map.get(s, "minLength", 0) and
        json_length(v) <= Map.get(s, "maxLength", 2048)

  defp pattern?(v, s),
    do:
      not Map.has_key?(s, "pattern") or
        Regex.match?(Regex.compile!(s["pattern"] <> "\\z"), v)

  # JavaScript counts UTF-16 code units, including in unknown extensions.
  defp json_length(v) do
    if String.valid?(v),
      do: div(byte_size(:unicode.characters_to_binary(v, :utf8, {:utf16, :little})), 2),
      else: 2049
  end

  defp alternatives(v, schemas) do
    Enum.find_value(schemas, :error, fn schema ->
      case validate(v, schema) do
        {:ok, clean} -> {:ok, clean}
        _ -> nil
      end
    end)
  end
end

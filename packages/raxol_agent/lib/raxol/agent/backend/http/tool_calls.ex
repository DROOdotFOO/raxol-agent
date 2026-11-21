defmodule Raxol.Agent.Backend.HTTP.ToolCalls do
  @moduledoc false
  # OpenAI-shape tool calls to the downstream contract: string keys
  # `"id"`, `"name"`, `"arguments"` (decoded). Arguments that do not decode
  # become `%{}` with an `"arguments_error"` marker beside them, never a
  # silent empty call. Blocking and streaming paths produce the same shape.

  @type acc :: %{non_neg_integer() => %{String.t() => term()}}

  @doc "Normalize a complete `tool_calls` list."
  @spec from_openai([map()]) :: [map()]
  def from_openai(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      build(tc["id"], get_in(tc, ["function", "name"]), get_in(tc, ["function", "arguments"]))
    end)
  end

  @doc """
  Merge one chunk's streamed fragments into `acc`. `id` and `name` come from
  the first fragment that carries them; string `arguments` concatenate, a
  map replaces them.
  """
  @spec merge(acc(), term()) :: acc()
  def merge(acc, frags), do: merge(acc, frags, :infinity)

  @doc """
  `merge/2` that stops once `acc` holds more than `max_calls` calls, so a
  chunk of fragments costs bounded work; `check_size/3` reports the excess.
  """
  @spec merge(acc(), term(), pos_integer() | :infinity) :: acc()
  def merge(acc, _frags, max_calls) when is_integer(max_calls) and map_size(acc) > max_calls,
    do: acc

  def merge(acc, frags, max_calls) when is_list(frags) do
    frags
    |> Enum.take(if max_calls == :infinity, do: length(frags), else: max_calls + 1)
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {frag, pos}, acc ->
      idx = index(acc, frag, pos)
      cur = Map.get(acc, idx, %{"id" => nil, "name" => nil, "args" => ""})
      fun = frag["function"] || %{}

      Map.put(acc, idx, %{
        "id" => frag["id"] || cur["id"],
        "name" => fun["name"] || cur["name"],
        "args" => merge_args(cur["args"], fun["arguments"])
      })
    end)
  end

  def merge(acc, _frags, _max_calls), do: acc

  defp merge_args(cur, s) when is_binary(s) and is_binary(cur), do: cur <> s
  defp merge_args(_cur, s) when is_binary(s), do: s
  defp merge_args(_cur, m) when is_map(m), do: m
  defp merge_args(cur, _other), do: cur

  # The provider's `index` when it is a non-negative integer (it is network
  # input, and a non-integer key would crash `next_index/1`). Otherwise a
  # repeated `id` lands on its own slot, and anything else gets a key past
  # every assigned one: `pos` restarts at 0 in every chunk.
  defp index(_acc, %{"index" => index}, _pos) when is_integer(index) and index >= 0, do: index

  defp index(acc, %{"id" => id}, pos) when not is_nil(id) do
    Enum.find_value(acc, next_index(acc) + pos, fn
      {idx, %{"id" => ^id}} -> idx
      _ -> nil
    end)
  end

  defp index(acc, _frag, pos), do: next_index(acc) + pos

  defp next_index(acc), do: Enum.max(Map.keys(acc), fn -> -1 end) + 1

  @doc """
  `:ok` while `acc` holds at most `max_calls` calls whose arguments (string
  bytes, or a map's external size) total at most `max_bytes`, else an error naming the limit. A streamed
  response is network input, and its fragments otherwise accumulate without
  bound.
  """
  @spec check_size(acc(), pos_integer(), pos_integer()) :: :ok | {:error, String.t()}
  def check_size(acc, max_bytes, max_calls) do
    bytes = for {_idx, %{"args" => a}} <- acc, reduce: 0, do: (n -> n + args_size(a))

    cond do
      map_size(acc) > max_calls ->
        {:error, "streamed response exceeded #{max_calls} tool calls"}

      bytes > max_bytes ->
        {:error, "streamed tool call arguments exceeded #{max_bytes} bytes"}

      true ->
        :ok
    end
  end

  defp args_size(a) when is_binary(a), do: byte_size(a)
  defp args_size(a) when is_map(a), do: :erlang.external_size(a)
  defp args_size(_a), do: 0

  @doc "The accumulated calls in index order."
  @spec finalize(acc()) :: [map()]
  def finalize(acc) do
    acc
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, tc} -> build(tc["id"], tc["name"], tc["args"]) end)
  end

  @doc "Fold per-chunk fragment batches into finalized calls, as a stream does."
  @spec accumulate([list()]) :: [map()]
  def accumulate(frag_batches) do
    frag_batches
    |> Enum.reduce(%{}, &merge(&2, &1))
    |> finalize()
  end

  defp build(id, name, raw_args) do
    base = %{"id" => id, "name" => name}

    case decode_args(raw_args) do
      {:ok, args} -> Map.put(base, "arguments", args)
      {:error, marker} -> Map.merge(base, %{"arguments" => %{}, "arguments_error" => marker})
    end
  end

  defp decode_args(""), do: {:ok, %{}}
  defp decode_args(nil), do: {:ok, %{}}
  defp decode_args(m) when is_map(m), do: {:ok, m}

  # The marker carries the size only, never the raw text.
  defp decode_args(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "⚠ undecodable tool call arguments (#{byte_size(s)} bytes)"}
    end
  end

  defp decode_args(_other), do: {:ok, %{}}
end

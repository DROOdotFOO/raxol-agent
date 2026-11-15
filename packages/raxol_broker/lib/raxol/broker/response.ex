defmodule Raxol.Broker.Response do
  @moduledoc """
  Reads a read tool's result (`Raxol.MCP.Client.call_tool/4`'s
  `{:ok, %{content: [...], is_error: false}}`): the JSON object in its first
  text block. Robinhood wraps a body as `{"data": ..., "guide": ...}`; the
  envelope is removed, so callers read the same shape from Robinhood and
  from `Raxol.Broker.MCP.Fake`, which answers unwrapped.
  """

  @doc "The body of a tool result, or `{:error, reason}`."
  @spec body({:ok, map()} | {:error, term()}) :: {:ok, map() | list()} | {:error, term()}
  def body(result) do
    with {:ok, decoded} <- decoded(result), do: {:ok, unwrap(decoded)}
  end

  @next_keys ["next", "next_cursor", "cursor"]

  @doc """
  One page of a cursored listing: `{:ok, items, next}`, with `items` the
  list under the first of `keys` the body holds and `next` the cursor for
  the following page (`nil` on the last). The cursor is read from the body
  or from Robinhood's envelope around it, so unwrapping never hides one.
  A body holding none of `keys` as a list is `{:error, :unreadable_listing}`:
  a listing that cannot be read is never taken for an empty one.
  """
  @spec page({:ok, map()} | {:error, term()}, [String.t()]) ::
          {:ok, list(), String.t() | nil} | {:error, term()}
  def page(result, keys) do
    with {:ok, decoded} <- decoded(result) do
      body = unwrap(decoded)

      case listed(body, keys) do
        {:ok, items} -> {:ok, items, cursor(body) || cursor(decoded)}
        :error -> {:error, :unreadable_listing}
      end
    end
  end

  defp listed(body, _keys) when is_list(body), do: {:ok, body}

  defp listed(body, keys) when is_map(body) do
    Enum.find_value(keys, :error, fn key ->
      case Map.get(body, key) do
        list when is_list(list) -> {:ok, list}
        _ -> nil
      end
    end)
  end

  defp cursor(map) when is_map(map) do
    Enum.find_value(@next_keys, fn key ->
      case Map.get(map, key) do
        next when is_binary(next) and next != "" -> next
        _ -> nil
      end
    end)
  end

  defp cursor(_list), do: nil

  defp decoded({:ok, %{is_error: false, content: content}}) when is_list(content) do
    Enum.find_value(content, {:error, :unreadable_response}, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _ -> nil
        end

      _block ->
        nil
    end)
  end

  defp decoded({:ok, %{is_error: true}}), do: {:error, :tool_error}
  defp decoded({:ok, _other}), do: {:error, :unreadable_response}
  defp decoded({:error, reason}), do: {:error, reason}

  @doc """
  The list under the first of `keys` present in `body`, or `body` itself
  when it is a list; `[]` when none is.
  """
  @spec list(map() | list(), [String.t()]) :: list()
  def list(body, _keys) when is_list(body), do: body

  def list(body, keys) when is_map(body) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(body, key) do
        list when is_list(list) -> list
        _ -> nil
      end
    end)
  end

  @doc "A decimal from a JSON string or integer, or nil."
  @spec decimal(term()) :: Decimal.t() | nil
  def decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = decimal, ""} when is_integer(coef) -> decimal
      _ -> nil
    end
  end

  def decimal(value) when is_integer(value), do: Decimal.new(value)
  def decimal(_value), do: nil

  defp unwrap(%{"data" => data}) when is_map(data) or is_list(data), do: data
  defp unwrap(body), do: body
end

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
  def body({:ok, %{is_error: false, content: content}}) when is_list(content) do
    Enum.find_value(content, {:error, :unreadable_response}, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{} = decoded} -> {:ok, unwrap(decoded)}
          _ -> nil
        end

      _block ->
        nil
    end)
  end

  def body({:ok, %{is_error: true}}), do: {:error, :tool_error}
  def body({:ok, _other}), do: {:error, :unreadable_response}
  def body({:error, reason}), do: {:error, reason}

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

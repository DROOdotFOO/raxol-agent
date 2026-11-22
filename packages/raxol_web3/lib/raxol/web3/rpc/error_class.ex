defmodule Raxol.Web3.RPC.ErrorClass do
  @moduledoc """
  The one JSON-RPC error-code table, shared by every path that reads a node or
  MCP error: `Raxol.Web3.RPC`, `Raxol.Web3.MCPCall` and the Tron and Solana
  backends.

  A code maps onto the class in `{:upstream_refused, class}`. The message is
  upstream prose and is never read. A backend whose upstream gives a code a
  chain-specific meaning passes an override map, which is consulted first.
  """

  @type class :: :not_found | :auth | :rate_limit | :unknown

  # -32004 is absent on purpose. On an EVM node it is a head block that has not
  # landed yet, which is transient and must stay `:unknown`; on Solana it is a
  # slot with no block, which is an answer. Only `Raxol.Web3.Backend.Solana.RPC`
  # overrides it.
  @classes %{
    -32_601 => :not_found,
    -32_602 => :not_found,
    401 => :auth,
    -32_001 => :auth,
    429 => :rate_limit,
    -32_005 => :rate_limit
  }

  @doc """
  The class of a JSON-RPC error object. Only an object carrying an integer
  `"code"` is classified; any other shape is `:unknown`.
  """
  @spec of_error(term(), %{integer() => class()}) :: class()
  def of_error(error, overrides \\ %{})
  def of_error(%{"code" => code}, overrides) when is_integer(code), do: of_code(code, overrides)
  def of_error(_error, _overrides), do: :unknown

  @doc """
  The class of a bare error code. `overrides` is consulted before the shared
  table; a non-integer or unknown code is `:unknown`.
  """
  @spec of_code(term(), %{integer() => class()}) :: class()
  def of_code(code, overrides \\ %{})

  def of_code(code, overrides) when is_integer(code) do
    Map.get(overrides, code) || Map.get(@classes, code, :unknown)
  end

  def of_code(_code, _overrides), do: :unknown
end

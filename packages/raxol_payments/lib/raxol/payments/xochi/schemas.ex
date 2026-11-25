defmodule Raxol.Payments.Xochi.Schemas do
  @moduledoc """
  Request/response schemas for the Xochi intent API, one module per wire
  object under `Raxol.Payments.Xochi.Schemas.*`: `QuoteRequest`,
  `DepositRouteRequest`, `QuoteResponse`, `ExecuteRequest`, `ExecuteResponse`,
  `IntentStatus` and `Intent`.
  """

  @eth_address_re ~r/\A0x[0-9a-fA-F]{40}\z/

  @doc false
  @spec validate_eth_address(String.t()) :: :ok | {:error, :invalid_address}
  def validate_eth_address(addr) when is_binary(addr) do
    if Regex.match?(@eth_address_re, addr), do: :ok, else: {:error, :invalid_address}
  end

  def validate_eth_address(_), do: {:error, :invalid_address}

  @doc false
  @spec put_non_nil(map(), String.t(), term()) :: map()
  def put_non_nil(map, _key, nil), do: map
  def put_non_nil(map, key, val), do: Map.put(map, key, val)

  @doc false
  @spec pick(map(), [String.t()]) :: term()
  def pick(json, keys), do: Enum.find_value(keys, fn key -> json[key] end)
end

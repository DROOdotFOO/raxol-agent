defmodule Raxol.Broker.Strategy.DipBuy do
  @moduledoc """
  Buy a dip: when a symbol's last price falls `dip` (a fraction, default
  `0.02`) or more below the highest price seen since the last buy, emit one
  limit buy in whole shares priced at that last price, for at most `usd`
  dollars.

  Parameters (`Raxol.Broker.Strategy` spec form, all strings):

    * `"symbol"` - the ticker.
    * `"usd"` - the most one order may cost; the quantity is
      `floor(usd / price)`, so a price above `usd` emits nothing.
    * `"dip"` - the fall that triggers a buy, in `(0, 1)` (default `"0.02"`).

  After a buy the reference resets to the buy price, so the next buy needs
  a fresh dip from there. Quotes for other symbols are ignored.
  """

  @behaviour Raxol.Broker.Strategy

  alias Raxol.Broker.Intent

  @default_dip "0.02"

  @enforce_keys [:symbol, :usd, :dip]
  defstruct [:symbol, :usd, :dip, high: nil]

  @impl true
  def init(params) when is_map(params) do
    with {:ok, symbol} <- symbol(Map.get(params, "symbol")),
         {:ok, usd} <- positive(Map.get(params, "usd"), :usd),
         {:ok, dip} <- fraction(Map.get(params, "dip", @default_dip)) do
      {:ok, %__MODULE__{symbol: symbol, usd: usd, dip: dip}}
    end
  end

  @impl true
  def symbols(%__MODULE__{symbol: symbol}), do: [symbol]

  @impl true
  def update({:quote, symbol, %{last: %Decimal{} = price}}, %__MODULE__{symbol: symbol} = model) do
    high = if model.high, do: Decimal.max(model.high, price), else: price
    trigger = Decimal.mult(high, Decimal.sub(1, model.dip))

    if Decimal.compare(price, trigger) != :gt and Decimal.gt?(price, 0),
      do: buy(%{model | high: high}, price),
      else: {%{model | high: high}, []}
  end

  def update(_message, model), do: {model, []}

  defp buy(model, price) do
    qty = model.usd |> Decimal.div_int(price)

    case Decimal.gt?(qty, 0) &&
           Intent.limit(:buy, model.symbol, qty, price,
             provenance: :strategy,
             strategy: "dip_buy"
           ) do
      {:ok, intent} -> {%{model | high: price}, [intent]}
      _none -> {model, []}
    end
  end

  defp symbol(value) when is_binary(value) do
    symbol = value |> String.trim() |> String.upcase()
    if Intent.symbol?(symbol), do: {:ok, symbol}, else: {:error, {:invalid_param, :symbol}}
  end

  defp symbol(_value), do: {:error, {:invalid_param, :symbol}}

  defp positive(value, key) do
    case decimal(value) do
      {:ok, decimal} -> if Decimal.gt?(decimal, 0), do: {:ok, decimal}, else: invalid(key)
      :error -> invalid(key)
    end
  end

  defp fraction(value) do
    with {:ok, dip} <- positive(value, :dip) do
      if Decimal.lt?(dip, 1), do: {:ok, dip}, else: invalid(:dip)
    end
  end

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = decimal, ""} when is_integer(coef) -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal(_value), do: :error

  defp invalid(key), do: {:error, {:invalid_param, key}}
end

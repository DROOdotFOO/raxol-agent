defmodule Raxol.Payments.Prices.Static do
  @moduledoc """
  A `price_fn` backed by a fixed symbol -> USD map, for tests and for runs where
  the operator supplies prices out of band.

      price_fn = Raxol.Payments.Prices.Static.price_fn(%{"ETH" => "1700", "POL" => "0.07"})
      price_fn.("ETH")     #=> Decimal.new("1700")
      price_fn.("UNKNOWN") #=> nil

  The prices are as of `:as_of` (Unix seconds, default when the fn is built)
  and answered while they are at most `:max_age_s` seconds old (a positive
  integer, default 300); after that, and for an `:as_of` in the future, every
  symbol is `nil`. Pass the time the operator read the prices as `:as_of`, and
  a longer `:max_age_s` for prices meant to hold longer.
  """

  @default_max_age_s 300

  @doc "Build a `(symbol -> Decimal.t() | nil)` from a symbol -> price map."
  @spec price_fn(%{String.t() => Decimal.t() | number() | String.t()}, keyword()) ::
          (String.t() -> Decimal.t() | nil)
  def price_fn(prices, opts \\ []) when is_map(prices) and is_list(opts) do
    as_of = Keyword.get_lazy(opts, :as_of, fn -> System.system_time(:second) end)
    max_age_s = Keyword.get(opts, :max_age_s, @default_max_age_s)

    unless is_integer(as_of), do: raise(ArgumentError, ":as_of must be Unix seconds")

    unless is_integer(max_age_s) and max_age_s > 0,
      do: raise(ArgumentError, ":max_age_s must be a positive integer")

    normalized = Map.new(prices, fn {symbol, value} -> {symbol, to_decimal(value)} end)

    fn symbol ->
      age = System.system_time(:second) - as_of
      if age >= 0 and age <= max_age_s, do: Map.get(normalized, symbol)
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(f) when is_float(f), do: Decimal.from_float(f)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end

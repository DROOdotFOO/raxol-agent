defmodule Raxol.Payments.Prices.CoinGecko do
  @moduledoc """
  A `price_fn` for native gas tokens and the non-dollar settlement assets it can
  price, backed by the public CoinGecko REST API.

  Fetches ETH, WETH, POL (Polygon), EURe (Monerium EUR e-money, quoted in USD,
  so about 1.1x a dollar rather than par), and RAXOL (Robinhood Chain) once
  when the fn is built and closes over them, so aggregation does not hit the
  network per lookup. Any failure (or a missing symbol) yields `nil` for that
  symbol, so `SettlementLedger` aggregations degrade to raw fee/gas totals
  rather than crashing -- a leg CoinGecko cannot price is reported unpriced,
  never at par.

  A price is answered only while CoinGecko's `last_updated_at` for it is at
  most `:max_age_s` seconds old (default 300) at the lookup, and `nil` after
  that or when the response carries no such time.

      price_fn = Raxol.Payments.Prices.CoinGecko.price_fn()
      Raxol.Payments.SettlementLedger.report(ledger, price_fn: price_fn)
  """

  @default_url "https://api.coingecko.com/api/v3/simple/price"
  @default_max_age_s 300

  # symbol -> CoinGecko coin id. Each non-native id is the coin CoinGecko maps
  # the canonical contract to: "monerium-eur-money-2" carries the current EURe
  # contracts (Arbitrum 0x0c06...44f8; "monerium-eur-money" is the retired v1
  # set), and "raxol" carries Robinhood Chain 0xf447...53af.
  @ids %{
    "ETH" => "ethereum",
    "WETH" => "weth",
    "POL" => "polygon-ecosystem-token",
    "EURe" => "monerium-eur-money-2",
    "RAXOL" => "raxol"
  }

  @doc """
  Build a `(symbol -> Decimal.t() | nil)` after one REST fetch.

  Options: `:url` (override endpoint), `:req_options` (extra `Req` options, e.g.
  `plug:` for `Req.Test`), `:max_age_s` (a positive integer, default
  #{@default_max_age_s}), `:raise_on_fetch_error` (default `false`: a failed
  fetch, a non-200 status or a body that is not a map, prices every symbol
  `nil`; `true` raises instead, so a caller can tell a failed fetch from a
  missing price).
  """
  @spec price_fn(keyword()) :: (String.t() -> Decimal.t() | nil)
  def price_fn(opts \\ []) do
    max_age_s = Keyword.get(opts, :max_age_s, @default_max_age_s)

    unless is_integer(max_age_s) and max_age_s > 0 do
      raise ArgumentError, ":max_age_s must be a positive integer, got #{inspect(max_age_s)}"
    end

    prices = fetch(opts, Keyword.get(opts, :raise_on_fetch_error, false))

    fn symbol -> fresh_price(Map.get(prices, symbol), max_age_s) end
  end

  defp fresh_price({price, updated_at}, max_age_s),
    do: if(fresh?(updated_at, max_age_s), do: price)

  defp fresh_price(nil, _max_age_s), do: nil

  defp fresh?(updated_at, max_age_s) do
    age = System.system_time(:second) - updated_at
    age >= 0 and age <= max_age_s
  end

  defp fetch(opts, raise?) do
    url = Keyword.get(opts, :url, @default_url)
    req_options = Keyword.get(opts, :req_options, [])
    ids = @ids |> Map.values() |> Enum.join(",")

    req =
      [
        url: url,
        params: [ids: ids, vs_currencies: "usd", include_last_updated_at: true]
      ]
      |> Keyword.merge(req_options)
      |> Req.new()

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> parse(body)
      result -> fetch_failed(result, raise?)
    end
  end

  defp fetch_failed(_result, false), do: %{}

  defp fetch_failed({:ok, %Req.Response{status: status}}, true),
    do: raise("CoinGecko price fetch failed: HTTP #{status}")

  defp fetch_failed({:error, exception}, true),
    do: raise("CoinGecko price fetch failed: #{inspect(exception.__struct__)}")

  defp parse(body) do
    @ids
    |> Enum.flat_map(fn {symbol, id} ->
      with %{} = coin <- Map.get(body, id),
           %Decimal{} = price <- to_price(coin["usd"]),
           updated_at when is_integer(updated_at) <- coin["last_updated_at"] do
        [{symbol, {price, updated_at}}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp to_price(n) when is_integer(n), do: Decimal.new(n)
  defp to_price(f) when is_float(f), do: Decimal.from_float(f)
  defp to_price(_value), do: nil
end

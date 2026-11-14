defmodule Raxol.Payments.Prices do
  @moduledoc """
  The configured USD price source.

  A price source is a `price_fn`: `(symbol -> Decimal.t() | nil)`, the
  symbol's price in US dollars, or `nil` when the source has none (an unknown
  symbol, a failed fetch, or a price older than the source accepts).
  `Prices.CoinGecko` and `Prices.Static` are sources; `Prices.FX` prices the
  euro and franc stablecoins in front of another.

  `config :raxol_payments, :accounting` selects them with `price_source:`
  (`:coingecko` or `:none`, default `:none`) and `fx:` (`Prices.FX` opts, or
  `nil`). `Raxol.Payments.Accounting.env_config/0` writes both from
  `RAXOL_PRICE_SOURCE` and `RAXOL_FX_ENABLED` when `RAXOL_ACCOUNTING_ENABLED`
  is `"true"`. `Raxol.Payments.RebalanceMonitor` reads both;
  `Raxol.Payments.SpendPricing` reads `price_source:` only, since no spend cap
  reads an FX rate.
  """

  alias Raxol.Payments.Prices.CoinGecko

  @type price_fn :: (String.t() -> Decimal.t() | nil)
  @type source :: :coingecko | :none

  @doc "The `price_source:` and `fx:` of `config :raxol_payments, :accounting`."
  @spec configured() :: %{price_source: term(), fx: keyword() | nil}
  def configured do
    accounting = Application.get_env(:raxol_payments, :accounting, [])

    %{
      price_source: Keyword.get(accounting, :price_source, :none),
      fx: Keyword.get(accounting, :fx)
    }
  end

  @doc """
  A `price_fn` for `source`, built now (`:coingecko` fetches once). `nil` for
  `:none` and for anything unrecognized, which prices nothing. `opts` go to
  the source's builder (`Prices.CoinGecko.price_fn/1`).
  """
  @spec source_fn(term(), keyword()) :: price_fn() | nil
  def source_fn(source, opts \\ [])
  def source_fn(:coingecko, opts), do: CoinGecko.price_fn(opts)
  def source_fn(_source, _opts), do: nil
end

defmodule Raxol.Payments.SpendPricing do
  @moduledoc """
  Converts a spend into the unit its `SpendingPolicy` caps are written in
  (`SpendingPolicy.unit/1`). `Raxol.Payments.Actions.SpendGate.authorize/3`
  runs it before the policy gate, the ledger reservation and any signature,
  and the converted amount is what is gated, reserved and released.

  A spend is a human amount of an asset:

    * `{:token, chain_id, address}` -- a token contract on a chain;
    * `{:symbol, ticker}` -- a ticker with no chain.

  Against the policy's unit:

    * A stablecoin pegged to the unit counts at par: a dollar stablecoin under
      a USD policy, EURC or EURe under EUR, ZCHF under CHF (`Assets.peg/2`,
      `Assets.symbol_peg/1`).
    * A stablecoin pegged to any other currency is refused. No spend cap reads
      an FX rate (ADR-0040 decision 7 is not built), so EURC, EURe and ZCHF
      are refused under a USD policy, and dollar stablecoins under a EUR or
      CHF one.
    * Under a USD policy, any other token (WETH, RAXOL, ETH) is converted at
      its USD price from the price source.
    * Under any other unit, any other token is refused: every price source
      quotes US dollars.

  The price source is the context's `:price_fn` (`(symbol -> Decimal.t() |
  nil)`, as `Raxol.Payments.RebalanceMonitor` takes) when it is set, and
  otherwise `price_source:` of `Raxol.Payments.Prices.configured/0`, built
  for the spend. Each source answers `nil` for a price older than it accepts:
  `Prices.CoinGecko` and `Prices.Static` past their `:max_age_s` (default 300
  seconds).

  A spend that cannot be converted is refused as `{:unpriced_asset, detail}`,
  `detail` carrying `side: :source`, the asset, its `peg`, the policy `unit`
  and a `reason`:

    * `:fx_unsupported` -- a stablecoin pegged to a currency other than the
      policy's;
    * `:policy_currency` -- any other token under a policy whose unit is not
      USD (or not a currency);
    * `:no_price_source` -- no `:price_fn` and no `price_source:` (or `:none`);
    * `:no_price` -- the source has no price for the symbol: unknown, missing
      or stale;
    * `:invalid_price` -- the price is not a positive finite `Decimal`, or the
      product is not representable;
    * `:price_source_error` -- building or calling the source raised, exited
      or threw;
    * `:invalid_asset` -- the asset is not one of the shapes above.
  """

  require Logger

  alias Raxol.Payments.{Assets, Prices, SpendingPolicy}

  @type asset :: {:token, integer() | String.t(), String.t()} | {:symbol, String.t()}

  @doc """
  `amount` (human units of `asset`) in the policy's unit. With no policy
  nothing caps the spend and `amount` is returned unchanged, but the asset
  shape is still checked and a stablecoin pegged to a currency other than the
  dollar is still refused (`:fx_unsupported`).
  """
  @spec to_policy_unit(SpendingPolicy.t() | nil, Decimal.t(), term(), map()) ::
          {:ok, Decimal.t()} | {:error, {:unpriced_asset, map()}}
  def to_policy_unit(policy, %Decimal{} = amount, asset, context) when is_map(context) do
    with {:ok, spend} <- describe(asset) do
      convert(policy, amount, spend, context)
    end
  end

  # Without a policy nothing is converted, but a non-USD stablecoin is refused,
  # so leaving the policy out does not open EURC, EURe or ZCHF sources.
  defp convert(nil, _amount, %{peg: peg} = spend, _context) when peg not in [nil, "USD"],
    do:
      {:error, {:unpriced_asset, Map.merge(spend.detail, %{unit: nil, reason: :fx_unsupported})}}

  defp convert(nil, amount, _spend, _context), do: {:ok, amount}

  # `SpendingPolicy.unit/1` is nil for a policy that is not a `SpendingPolicy`.
  defp convert(policy, amount, spend, context) do
    unit = SpendingPolicy.unit(policy)

    result =
      case rate(spend, unit, context) do
        :par -> {:ok, amount}
        {:ok, price} -> multiply(amount, price)
        {:error, _reason} = error -> error
      end

    case result do
      {:ok, _converted} = ok ->
        ok

      {:error, reason} ->
        {:error, {:unpriced_asset, Map.merge(spend.detail, %{unit: unit, reason: reason})}}
    end
  end

  defp describe({:token, chain_id, address} = asset) when is_binary(address) do
    symbol = Assets.symbol_for(chain_id, address)
    peg = Assets.peg(chain_id, address)

    {:ok,
     %{
       symbol: symbol,
       peg: peg,
       detail: %{side: :source, asset: asset, chain_id: chain_id, token: address, peg: peg}
     }}
  end

  defp describe({:symbol, ticker} = asset) when is_binary(ticker) do
    peg = Assets.symbol_peg(ticker)

    {:ok,
     %{
       symbol: price_symbol(ticker),
       peg: peg,
       detail: %{side: :source, asset: asset, symbol: ticker, peg: peg}
     }}
  end

  defp describe(asset),
    do: {:error, {:unpriced_asset, %{side: :source, asset: asset, reason: :invalid_asset}}}

  # A ticker is priced in folded form.
  defp price_symbol(ticker), do: Assets.fold_symbol(ticker)

  defp rate(_spend, nil, _context), do: {:error, :policy_currency}
  defp rate(%{peg: unit}, unit, _context), do: :par
  defp rate(%{peg: peg}, _unit, _context) when is_binary(peg), do: {:error, :fx_unsupported}
  defp rate(_spend, unit, _context) when unit != "USD", do: {:error, :policy_currency}
  defp rate(%{symbol: symbol}, "USD", context), do: lookup(symbol, context)

  defp lookup(nil, _context), do: {:error, :no_price}
  defp lookup(symbol, context), do: price(source(context), symbol)

  # The context's `:price_fn` wins; otherwise the configured source, built when
  # the price is read. `Prices.source_fn/1` is nil for `:none` and anything it
  # does not know.
  defp source(context) do
    case Map.get(context, :price_fn) do
      price_fn when is_function(price_fn, 1) -> fn -> price_fn end
      _ -> fn -> Prices.source_fn(Prices.configured().price_source) end
    end
  end

  defp price(build, symbol) do
    case build.() do
      nil -> {:error, :no_price_source}
      price_fn -> symbol |> price_fn.() |> validate_price()
    end
  rescue
    error -> source_failed(error.__struct__)
  catch
    kind, _reason -> source_failed(kind)
  end

  defp validate_price(%Decimal{coef: coef} = price) when is_integer(coef) do
    if Decimal.compare(price, 0) == :gt, do: {:ok, price}, else: {:error, :invalid_price}
  end

  defp validate_price(nil), do: {:error, :no_price}
  defp validate_price(_price), do: {:error, :invalid_price}

  # Only the exception module or the throw kind is logged: a message could
  # carry upstream data.
  defp source_failed(what) do
    Logger.warning("Spend price source failed (#{inspect(what)}); spend refused")
    {:error, :price_source_error}
  end

  defp multiply(amount, price) do
    case Decimal.mult(amount, price) do
      %Decimal{coef: coef} = converted when is_integer(coef) -> {:ok, converted}
      _ -> {:error, :invalid_price}
    end
  rescue
    Decimal.Error -> {:error, :invalid_price}
  end
end

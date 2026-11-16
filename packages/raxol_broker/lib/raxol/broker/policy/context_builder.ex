defmodule Raxol.Broker.Policy.ContextBuilder do
  @moduledoc """
  The context fields the executor fetches itself instead of trusting its
  caller: `quotes`, `positions`, `portfolio_value`, `start_of_day_value`,
  `day_pnl`, `market_session` and `trading_day`.

    * `quotes`: `get_equity_quotes` for the intent's symbol, its last trade
      price.
    * `positions`: every page of `get_equity_positions` for the account,
      each position's `market_value`, or its quantity times the last price
      when the answer carries no value and the symbol was quoted. `nil`
      when the listing fails, is unreadable or runs past its page limit, and
      when the intent's own symbol is held but cannot be valued: a holding
      read as zero would let a concentrated buy through.
    * `portfolio_value`: the live USD `total_value` from `get_portfolio`.
    * `start_of_day_value`: the journal's persisted observation from the
      first 60 seconds after New York midnight for this exact account/day.
      A missed capture is not replaced by an intraday or previous-close value.
    * `day_pnl`: current total minus that observation, including unrealized
      changes but not adjusted for deposits or withdrawals.
    * `market_session`: `Raxol.Broker.MarketCalendar.session/1` at the executor's
      clock.
    * `trading_day`: `Raxol.Broker.MarketCalendar.trading_day?/1` at the same
      clock, distinct from an overnight closed session on a trading date.

  A read that fails leaves its fields `nil`, so every rule that needs one
  denies with `{:missing_context, field}`: an unreadable portfolio never
  lets an order through a rule that needs it.
  """

  alias Raxol.Broker.{Feed, Intent, Journal, MarketCalendar, Response}
  alias Raxol.Broker.Executor.Read
  alias Raxol.Broker.Policy.Context

  alias Raxol.Broker.Journal.Codec

  @type env :: %{
          port: term(),
          catalog: map(),
          account: String.t(),
          journal: Journal.server(),
          timeout: timeout(),
          now: DateTime.t()
        }

  @doc "Fill `context`'s fetched fields for `intent`; see the moduledoc."
  @spec build(Intent.t(), Context.t(), env()) :: Context.t()
  def build(%Intent{} = intent, %Context{} = context, env) do
    quotes = quotes(intent, env)
    positions = positions(intent, env, quotes)
    {value, start} = portfolio(env)

    %{
      context
      | quotes: quotes,
        positions: positions,
        portfolio_value: value,
        start_of_day_value: start,
        day_pnl: value && start && Decimal.sub(value, start),
        market_session: MarketCalendar.session(env.now),
        trading_day: MarketCalendar.trading_day?(env.now)
    }
  end

  defp quotes(%Intent{symbol: nil}, _env), do: %{}

  defp quotes(%Intent{symbol: symbol}, env) do
    case read(env, "get_equity_quotes", %{"symbols" => [symbol]}) do
      {:ok, body} -> Map.new(Feed.quotes(body), fn {s, quote} -> {s, quote.last} end)
      {:error, _reason} -> %{}
    end
  end

  defp positions(intent, env, quotes) do
    args = %{"account_number" => env.account}

    with {:ok, listed} <-
           Read.listing(
             env.port,
             env.catalog,
             "get_equity_positions",
             args,
             ["positions", "results"],
             env.timeout
           ),
         {:ok, values} <- position_values(listed, intent.symbol, quotes) do
      Map.new(values)
    else
      {:error, _reason} -> nil
    end
  end

  # A position of the intent's own symbol that cannot be valued voids the
  # map; one of another symbol is left out (the weight rule reads only the
  # intent's symbol).
  defp position_values(listed, symbol, quotes) do
    Enum.reduce_while(listed, {:ok, []}, fn position, {:ok, acc} ->
      case {position_value(position, quotes), position} do
        {{:ok, value}, _position} -> {:cont, {:ok, [value | acc]}}
        {:error, %{"symbol" => ^symbol}} -> {:halt, {:error, :unvalued}}
        {:error, _other} -> {:cont, {:ok, acc}}
      end
    end)
  end

  defp position_value(%{"symbol" => symbol} = position, quotes) when is_binary(symbol) do
    value =
      Response.decimal(position["market_value"]) ||
        times(Response.decimal(position["quantity"]), Map.get(quotes, symbol))

    if value, do: {:ok, {symbol, value}}, else: :error
  end

  defp position_value(_position, _quotes), do: :error

  defp times(%Decimal{} = qty, %Decimal{} = price), do: Decimal.mult(qty, price)
  defp times(_qty, _price), do: nil

  defp portfolio(env) do
    case read(env, "get_portfolio", %{"account_number" => env.account}) do
      {:ok, %{} = body} ->
        value =
          case Codec.portfolio_value(body) do
            {:ok, value} -> value
            {:error, _reason} -> nil
          end

        start =
          case Journal.day_baseline(env.account, MarketCalendar.day_start(env.now), env.journal) do
            {:ok, %Decimal{coef: coef, sign: 1} = value} when is_integer(coef) and coef > 0 ->
              value

            _missing ->
              nil
          end

        {value, start}

      _unreadable ->
        {nil, nil}
    end
  end

  defp read(env, tool, args), do: Read.call(env.port, env.catalog, tool, args, env.timeout)
end

defmodule Raxol.Broker.Policy.ContextBuilder do
  @moduledoc """
  The context fields the executor fetches itself instead of trusting its
  caller: `quotes`, `positions`, `portfolio_value`, `start_of_day_value`,
  `day_pnl` and `market_session`.

    * `quotes`: `get_equity_quotes` for the intent's symbol, its last trade
      price.
    * `positions`: `get_equity_positions` for the account, each position's
      `market_value`, or its quantity times the last price when the answer
      carries no value and the symbol was quoted.
    * `portfolio_value` and `start_of_day_value`: `get_portfolio` for the
      account; the first present of `equity`, `total_value`,
      `portfolio_value` and of `adjusted_equity_previous_close`,
      `equity_previous_close`, `previous_close`.
    * `day_pnl`: `portfolio_value - start_of_day_value`, realized and
      unrealized together.
    * `market_session`: `Raxol.Broker.MarketCalendar.session/1` at the executor's
      clock.

  A read that fails leaves its fields `nil`, so every rule that needs one
  denies with `{:missing_context, field}`: an unreadable portfolio never
  lets an order through a rule that needs it.
  """

  alias Raxol.Broker.{Feed, Intent, MarketCalendar, Response}
  alias Raxol.Broker.Executor.Read
  alias Raxol.Broker.Policy.Context

  @current ["equity", "total_value", "portfolio_value"]
  @start ["adjusted_equity_previous_close", "equity_previous_close", "previous_close"]

  @type env :: %{
          port: term(),
          catalog: map(),
          account: String.t(),
          timeout: timeout(),
          now: DateTime.t()
        }

  @doc "Fill `context`'s fetched fields for `intent`; see the moduledoc."
  @spec build(Intent.t(), Context.t(), env()) :: Context.t()
  def build(%Intent{} = intent, %Context{} = context, env) do
    quotes = quotes(intent, env)
    positions = positions(env, quotes)
    {value, start} = portfolio(env)

    %{
      context
      | quotes: quotes,
        positions: positions,
        portfolio_value: value,
        start_of_day_value: start,
        day_pnl: value && start && Decimal.sub(value, start),
        market_session: MarketCalendar.session(env.now)
    }
  end

  defp quotes(%Intent{symbol: nil}, _env), do: %{}

  defp quotes(%Intent{symbol: symbol}, env) do
    case read(env, "get_equity_quotes", %{"symbols" => [symbol]}) do
      {:ok, body} -> Map.new(Feed.quotes(body), fn {s, quote} -> {s, quote.last} end)
      {:error, _reason} -> %{}
    end
  end

  defp positions(env, quotes) do
    case read(env, "get_equity_positions", %{"account_number" => env.account}) do
      {:ok, body} ->
        body
        |> Response.list(["positions", "results"])
        |> Enum.flat_map(&position_value(&1, quotes))
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  defp position_value(%{"symbol" => symbol} = position, quotes) when is_binary(symbol) do
    value =
      Response.decimal(position["market_value"]) ||
        times(Response.decimal(position["quantity"]), Map.get(quotes, symbol))

    if value, do: [{symbol, value}], else: []
  end

  defp position_value(_position, _quotes), do: []

  defp times(%Decimal{} = qty, %Decimal{} = price), do: Decimal.mult(qty, price)
  defp times(_qty, _price), do: nil

  defp portfolio(env) do
    case read(env, "get_portfolio", %{"account_number" => env.account}) do
      {:ok, %{} = body} -> {first(body, @current), first(body, @start)}
      _unreadable -> {nil, nil}
    end
  end

  defp first(body, keys), do: Enum.find_value(keys, &Response.decimal(body[&1]))

  defp read(env, tool, args), do: Read.call(env.port, env.catalog, tool, args, env.timeout)
end

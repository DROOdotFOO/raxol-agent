defmodule Raxol.Broker.Snapshot do
  @moduledoc """
  What `mix raxol.broker.inspect` prints: accounts and buying power,
  positions, the mode, the journal's status, and the policy's verdict for a
  sample intent.

  Everything is read through the read-only `Raxol.Broker.MCP.Client`, so
  nothing here can review, place or cancel. The verdict is
  `Raxol.Broker.Policy.evaluate/2` on a context built from the policy, the
  sample's quote, the positions and the journal's counters; no review runs,
  so it is the pre-review verdict.

  Samples: `"buy SYM 100usd"`, `"buy SYM 2"`, `"sell SYM 2"`,
  `"buy SYM 2 @ 10.50"`.
  """

  alias Raxol.Broker.{Feed, Intent, Journal, MarketCalendar, Mode, Policy, Response}
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Policy.Context

  @doc """
  The report's lines. Options: `:client`, `:journal`, `:policy` (a validated
  policy keyword list), `:sample` (nil for none), `:now` (UTC `DateTime`).
  """
  @spec lines(keyword()) :: [String.t()]
  def lines(opts) do
    client = Keyword.fetch!(opts, :client)
    journal = Keyword.fetch!(opts, :journal)
    accounts = accounts(client)

    Enum.concat([
      account_lines(client, accounts),
      position_lines(client, accounts),
      ["mode: #{Mode.current(journal)}", "journal: #{status(journal)}"],
      sample_lines(opts[:sample], client, journal, opts)
    ])
  end

  @doc "Parse a sample intent; see the moduledoc."
  @spec sample(String.t()) :: {:ok, Intent.t()} | {:error, term()}
  def sample(text) do
    opts = [provenance: :human]

    case String.split(text) do
      [side, symbol, qty, "@", price] when side in ["buy", "sell"] ->
        with {:ok, qty} <- number(qty),
             {:ok, price} <- number(price),
             do: Intent.limit(String.to_existing_atom(side), symbol, qty, price, opts)

      ["buy", symbol, amount] ->
        if String.ends_with?(amount, "usd") do
          with {:ok, usd} <- number(String.trim_trailing(amount, "usd")),
               do: Intent.buy_usd(symbol, usd, opts)
        else
          with {:ok, qty} <- number(amount), do: Intent.buy_shares(symbol, qty, opts)
        end

      ["sell", symbol, qty] ->
        with {:ok, qty} <- number(qty), do: Intent.sell(symbol, qty, opts)

      _other ->
        {:error, {:unreadable_sample, text}}
    end
  end

  defp number(text) do
    case Decimal.parse(text) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> {:error, {:not_a_number, text}}
    end
  end

  defp accounts(client) do
    case read(client, "get_accounts", %{}) do
      {:ok, body} -> {:ok, Response.list(body, ["accounts", "results"])}
      error -> error
    end
  end

  # `get_accounts` does not carry reliable buying power (its own description
  # says so); `get_portfolio` does, for the agentic account.
  defp account_lines(client, {:ok, accounts}) do
    Enum.map(accounts, fn account ->
      agentic? = account["agentic_allowed"] == true
      line = "account #{account["account_number"]}: agentic_allowed=#{agentic?}"

      if agentic?,
        do: line <> " buying_power=#{buying_power(client, account["account_number"])}",
        else: line
    end)
  end

  defp account_lines(_client, {:error, reason}),
    do: ["accounts: unreadable (#{inspect(reason, structs: false)})"]

  @doc "The buying power `get_portfolio` reports for `account`, as text (`?` when unreadable)."
  @spec buying_power(GenServer.server(), String.t()) :: String.t()
  def buying_power(client, account) do
    case read(client, "get_portfolio", %{"account_number" => account}) do
      {:ok, %{"buying_power" => value}} when is_binary(value) -> value
      {:ok, %{"buying_power" => %{"amount" => value}}} when is_binary(value) -> value
      _unreadable -> "?"
    end
  end

  defp position_lines(client, {:ok, accounts}) do
    for %{"account_number" => number, "agentic_allowed" => true} <- accounts do
      case read(client, "get_equity_positions", %{"account_number" => number}) do
        {:ok, body} ->
          case Response.list(body, ["positions", "results"]) do
            [] -> "positions #{number}: none"
            list -> "positions #{number}: " <> Enum.map_join(list, ", ", &position/1)
          end

        {:error, reason} ->
          "positions #{number}: unreadable (#{inspect(reason, structs: false)})"
      end
    end
  end

  defp position_lines(_client, _unreadable), do: []

  defp position(%{"symbol" => symbol} = position),
    do: "#{symbol} #{position["quantity"] || position["qty"] || "?"}"

  defp position(_other), do: "?"

  defp status(journal) do
    case Journal.status(journal) do
      :ok -> "ok"
      {:damaged, offset} -> "damaged at offset #{offset}"
      {:error, reason} -> "unavailable (#{inspect(reason, structs: false)})"
    end
  end

  defp sample_lines(nil, _client, _journal, _opts), do: []

  defp sample_lines(text, client, journal, opts) do
    case sample(text) do
      {:ok, intent} ->
        context = context(intent, client, journal, opts)
        ["sample #{text}: #{verdict(Policy.evaluate(intent, context))} (no order placed)"]

      {:error, reason} ->
        ["sample #{text}: #{inspect(reason, structs: false)}"]
    end
  end

  defp context(intent, client, journal, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    quotes =
      case read(client, "get_equity_quotes", %{"symbols" => [intent.symbol]}) do
        {:ok, body} -> Map.new(Feed.quotes(body), fn {symbol, quote} -> {symbol, quote.last} end)
        {:error, _reason} -> %{}
      end

    %Context{
      policy: Keyword.fetch!(opts, :policy),
      quotes: quotes,
      market_session: MarketCalendar.session(now),
      today_notional: counter(Journal.today_notional(MarketCalendar.day_start(now), journal)),
      orders_last_minute: counter(Journal.orders_last_minute(now, journal))
    }
  end

  defp counter({:ok, value}), do: value
  defp counter({:error, _reason}), do: nil

  defp verdict({:allow, _intent}), do: "ALLOW"

  defp verdict({:ask, asks}),
    do: "ASK " <> Enum.map_join(asks, "; ", fn {rule, _} -> "#{rule}" end)

  defp verdict({:deny, {rule, detail}}), do: "DENY #{rule} #{inspect(detail, structs: false)}"

  defp read(client, tool, args) do
    Response.body(Client.call(client, tool, args))
  catch
    :exit, reason -> {:error, {:client_down, reason}}
  end
end

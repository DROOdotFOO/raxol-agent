defmodule Raxol.Broker.Feed do
  @moduledoc """
  Polls `get_equity_quotes` for the symbols its subscribers want and sends
  each subscriber `{:quote, symbol, %{last: Decimal.t(), bid: Decimal.t() |
  nil, ask: Decimal.t() | nil}}` for its symbols.

  Robinhood documents no push channel and no rate limits, so polling is
  conservative:

    * One poll every `:interval` milliseconds (default 15_000), each taking a
      grant from the shared `Raxol.Broker.Feed.Bucket` first. When the
      bucket is empty the poll waits for the time it names.
    * A `429` or `5xx` answer backs off: the next poll waits a delay doubling
      from `:backoff_ms` (default 1_000) up to `:max_backoff_ms` (default
      300_000), drawn between half the delay and all of it. A `:poll`
      message arriving before that is ignored. Any answer that is not a
      throttle resets the backoff.
    * Any other failure is logged and the next poll waits one interval.

  Quotes are read through the read-only `Raxol.Broker.MCP.Client` (`:client`),
  so the feed can never reach a review or order tool.

  ## Options

  `:client` (required), `:bucket` (default `Raxol.Broker.Feed.Bucket`),
  `:interval`, `:backoff_ms`, `:max_backoff_ms`, `:clock` (zero-arity,
  monotonic milliseconds), `:schedule` (a one-arity function given the delay
  in milliseconds until the next poll; default sends `:poll` to the feed
  after it), `:name`.
  """

  use GenServer

  require Logger

  alias Raxol.Broker.Feed.Bucket
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Response

  @default_interval 15_000
  @default_backoff 1_000
  @default_max_backoff 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Send the calling process quotes for `symbols` (added to any it already
  has). A cast: it returns at once, even while the feed waits on a poll.
  """
  @spec subscribe(GenServer.server(), [String.t()]) :: :ok
  def subscribe(feed, symbols) when is_list(symbols),
    do: GenServer.cast(feed, {:subscribe, self(), symbols})

  @doc "Stop sending the calling process quotes."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(feed), do: GenServer.call(feed, {:unsubscribe, self()})

  @doc "Parse nested `results[].quote` bodies; malformed or contradictory rows are skipped."
  @spec quotes(term()) :: %{String.t() => map()}
  def quotes(%{"results" => results}) when is_list(results) do
    results
    |> Enum.flat_map(fn
      %{"quote" => %{"symbol" => symbol} = quote} = row
      when is_binary(symbol) and symbol != "" ->
        with true <- not Map.has_key?(row, "symbol") or row["symbol"] == symbol,
             %Decimal{} = last <- Response.decimal(quote["last_trade_price"]),
             true <- Decimal.gt?(last, 0) do
          [
            {symbol,
             %{
               last: last,
               bid: Response.decimal(quote["bid_price"]),
               ask: Response.decimal(quote["ask_price"])
             }}
          ]
        else
          _invalid -> []
        end

      _row ->
        []
    end)
    |> Map.new()
  end

  def quotes(_body), do: %{}

  @impl GenServer
  def init(opts) do
    me = self()

    state = %{
      client: Keyword.fetch!(opts, :client),
      bucket: Keyword.get(opts, :bucket, Bucket),
      interval: Keyword.get(opts, :interval, @default_interval),
      backoff_ms: Keyword.get(opts, :backoff_ms, @default_backoff),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      schedule:
        Keyword.get(opts, :schedule, fn delay -> Process.send_after(me, :poll, delay) end),
      subscribers: %{},
      due_at: nil,
      throttled: 0
    }

    {:ok, %{state | due_at: state.clock.()}}
  end

  @impl GenServer
  def handle_cast({:subscribe, pid, symbols}, state) do
    first? = map_size(state.subscribers) == 0

    subscribers =
      Map.update(state.subscribers, pid, {Process.monitor(pid), MapSet.new(symbols)}, fn
        {ref, held} -> {ref, MapSet.union(held, MapSet.new(symbols))}
      end)

    if first?, do: state.schedule.(max(state.due_at - state.clock.(), 0))
    {:noreply, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_call({:unsubscribe, pid}, _from, state), do: {:reply, :ok, drop(state, pid)}

  @impl GenServer
  def handle_info(:poll, state) do
    now = state.clock.()

    cond do
      now < state.due_at -> {:noreply, state}
      map_size(state.subscribers) == 0 -> {:noreply, state}
      true -> {:noreply, take(state, now)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(state, pid)}
  def handle_info(_message, state), do: {:noreply, state}

  defp drop(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {{ref, _symbols}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}

      {nil, _subscribers} ->
        state
    end
  end

  defp take(state, now) do
    case Bucket.take(state.bucket) do
      :ok -> poll(state, now)
      {:wait, ms} -> next(state, now, ms)
    end
  end

  defp poll(state, now) do
    symbols = state.subscribers |> Map.values() |> Enum.flat_map(&MapSet.to_list(elem(&1, 1)))
    symbols = symbols |> Enum.uniq() |> Enum.sort()

    case fetch(state.client, symbols) do
      {:ok, quotes} ->
        deliver(state, quotes)
        next(%{state | throttled: 0}, now, state.interval)

      {:error, {:http, status}} when status == 429 or status in 500..599 ->
        throttled = state.throttled + 1
        Logger.warning("[Broker.Feed] quotes answered #{status}; backing off")
        next(%{state | throttled: throttled}, now, backoff(state, throttled))

      {:error, reason} ->
        Logger.warning("[Broker.Feed] quotes failed: #{inspect(reason, structs: false)}")
        next(%{state | throttled: 0}, now, state.interval)
    end
  end

  defp fetch(client, symbols) do
    with {:ok, body} <-
           Response.body(Client.call(client, "get_equity_quotes", %{"symbols" => symbols})),
         do: {:ok, quotes(body)}
  catch
    :exit, reason -> {:error, {:client_down, reason}}
  end

  defp deliver(state, quotes) do
    for {pid, {_ref, symbols}} <- state.subscribers,
        {symbol, quote} <- quotes,
        MapSet.member?(symbols, symbol) do
      send(pid, {:quote, symbol, quote})
    end
  end

  defp backoff(state, throttled) do
    delay = min(state.backoff_ms * Integer.pow(2, throttled - 1), state.max_backoff_ms)
    half = div(delay, 2)
    half + :rand.uniform(delay - half + 1) - 1
  end

  defp next(state, now, delay) do
    state.schedule.(delay)
    %{state | due_at: now + delay}
  end
end

defmodule Raxol.Broker.FeedTest do
  @moduledoc """
  The quote feed against the Fake through the read-only client, with an
  injected clock and scheduler: polls are driven by sending `:poll`.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Feed
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    fake = Fake.start(quotes: %{"F" => "9.80", "AAPL" => "125"})
    client = start_supervised!({Client, Fake.client_opts(fake, backoff: [retries: 0])})
    {clock, time} = Broker.clock(0)
    {:ok, fake: fake, client: client, clock: clock, time: time}
  end

  defp bucket!(ctx, opts \\ []) do
    id = {Feed.Bucket, System.unique_integer([:positive])}
    name = :"bucket_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, clock: ctx.clock], opts)
    start_supervised!(Supervisor.child_spec({Feed.Bucket, opts}, id: id))
    name
  end

  defp feed!(ctx, bucket, opts \\ []) do
    test = self()

    opts =
      Keyword.merge(
        [
          client: ctx.client,
          bucket: bucket,
          clock: ctx.clock,
          interval: 1_000,
          backoff_ms: 4_000,
          schedule: fn delay -> send(test, {:scheduled, self(), delay}) end
        ],
        opts
      )

    start_supervised!(Supervisor.child_spec({Feed, opts}, id: System.unique_integer()))
  end

  defp advance(ctx, ms), do: Agent.update(ctx.time, &(&1 + ms))

  # The feed answers this only after every message sent before it.
  defp poll!(feed) do
    send(feed, :poll)
    :sys.get_state(feed)
  end

  defp quote_calls(fake),
    do: Enum.count(Fake.requests(fake), &match?({"tools/call", "get_equity_quotes", _}, &1))

  test "subscribers get quotes for their own symbols only", ctx do
    feed = feed!(ctx, bucket!(ctx))
    :ok = Feed.subscribe(feed, ["F"])
    poll!(feed)

    assert_received {:quote, "F", %{last: last}}
    assert Decimal.equal?(last, Decimal.new("9.80"))
    refute_received {:quote, "AAPL", _}
  end

  test "a 429 backs the feed off: no poll inside the window, then it resumes", ctx do
    feed = feed!(ctx, bucket!(ctx))
    :ok = Feed.subscribe(feed, ["F"])

    poll!(feed)
    assert_received {:quote, "F", _}
    advance(ctx, 1_000)
    poll!(feed)
    assert_received {:quote, "F", _}

    Fake.inject(ctx.fake, [{"get_equity_quotes", {:http, 429}}])
    advance(ctx, 1_000)
    poll!(feed)
    refute_received {:quote, "F", _}
    assert_received {:scheduled, ^feed, 0}
    assert_received {:scheduled, ^feed, 1_000}
    assert_received {:scheduled, ^feed, 1_000}
    assert_received {:scheduled, ^feed, window}
    assert window >= 2_000 and window <= 4_000

    calls = quote_calls(ctx.fake)
    advance(ctx, window - 1)
    poll!(feed)
    assert quote_calls(ctx.fake) == calls

    advance(ctx, 1)
    poll!(feed)
    assert_received {:quote, "F", _}
    assert quote_calls(ctx.fake) == calls + 1
  end

  test "two feeds sharing a 10-per-minute bucket never poll more than 10 times a minute", ctx do
    bucket = bucket!(ctx, limit: 10, window: 60_000)
    feeds = [feed!(ctx, bucket), feed!(ctx, bucket)]
    for {feed, symbol} <- Enum.zip(feeds, ["F", "AAPL"]), do: :ok = Feed.subscribe(feed, [symbol])

    for _second <- 1..59 do
      Enum.each(feeds, &poll!/1)
      advance(ctx, 1_000)
    end

    assert quote_calls(ctx.fake) == 10

    advance(ctx, 1_000)
    Enum.each(feeds, &poll!/1)
    assert quote_calls(ctx.fake) > 10
  end

  test "poll failures log the error tag without response details", ctx do
    client =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:call, "get_equity_quotes", _args, _timeout}} ->
            GenServer.reply(from, {:error, {:transport, %{token: "feed-secret"}}})
        end
      end)

    feed = feed!(ctx, bucket!(ctx), client: client)
    :ok = Feed.subscribe(feed, ["F"])

    log = ExUnit.CaptureLog.capture_log(fn -> poll!(feed) end)
    assert log =~ "quotes failed: {:transport, :error}"
    refute log =~ "feed-secret"
  end

  test "quotes/1 reads Robinhood's quote fields and skips malformed entries" do
    body = %{
      "quotes" => [
        %{
          "symbol" => "F",
          "last_trade_price" => "12.255000",
          "bid_price" => "12.11",
          "ask_price" => "12.35"
        },
        %{"symbol" => "X"},
        "junk"
      ]
    }

    assert %{"F" => %{last: last, bid: bid, ask: ask}} = Feed.quotes(body)
    assert Decimal.equal?(last, Decimal.new("12.255"))
    assert Decimal.equal?(bid, Decimal.new("12.11")) and Decimal.equal?(ask, Decimal.new("12.35"))
    assert map_size(Feed.quotes(body)) == 1
  end
end

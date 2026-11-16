defmodule Raxol.Broker.DailyBaselineTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal, MarketCalendar, Mode}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @day ~U[2026-10-02 04:00:00Z]

  defp portfolio(value), do: %{"total_value" => value, "currency" => "USD"}

  test "captures live total, persists across journal and worker restart, and never resets losses" do
    fake = Fake.start(portfolio: Map.put(portfolio("1000"), "equity", "1"))
    ctx = Broker.baseline_journal!(fake)
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, Broker.d("1000")}
    [record] = Broker.records(ctx.path)
    assert record["type"] == "day_baseline"
    assert record["day_start"] == "2026-10-02T04:00:00Z"
    assert record["observed_at"] == record["at"]
    assert Journal.verify(ctx.journal) == :ok

    Fake.portfolio(fake, portfolio("900"))
    calls = Fake.calls(fake, "get_")
    GenServer.stop(ctx.baseline.worker)
    GenServer.stop(ctx.journal)
    Broker.start_journal!(ctx.journal_opts)
    Broker.capture_baseline!(ctx.journal, fake, ctx.clock)
    assert Fake.calls(fake, "get_") == calls
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, Broker.d("1000")}
    assert length(Broker.records(ctx.path)) == 1

    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    executor =
      Broker.executor!(ctx.journal, fake,
        policy: Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05"))
      )

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :strategy)

    assert {:deny, _, {:drawdown_breaker, _}} = Executor.run(executor, intent, %Context{})
    assert Mode.current(ctx.journal) == :disarmed
    assert Fake.calls(fake, "place_") == []
  end

  test "account and exact New York day are isolated" do
    fake = Fake.start(portfolio: portfolio("1000"))
    ctx = Broker.baseline_journal!(fake)
    assert Journal.day_baseline("OTHER", @day, ctx.journal) == {:ok, nil}

    assert Journal.day_baseline("FAKE-0001", DateTime.add(@day, 86_400), ctx.journal) ==
             {:ok, nil}

    assert Journal.day_baseline("FAKE-0001", DateTime.add(@day, 1), ctx.journal) == {:ok, nil}
  end

  test "missed window never reads or synthesizes a baseline from caller or previous-close fields" do
    fake =
      Fake.start(
        portfolio:
          Map.merge(portfolio("900"), %{
            "adjusted_equity_previous_close" => "1000",
            "equity_previous_close" => "1000",
            "previous_close" => "1000"
          })
      )

    ctx = Broker.journal!()
    Broker.capture_baseline!(ctx.journal, fake, &Broker.t0/0)
    assert Fake.calls(fake, "get_") == []
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}

    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    executor =
      Broker.executor!(ctx.journal, fake,
        policy: Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05"))
      )

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :strategy)

    lying = %Context{start_of_day_value: Broker.d("900"), day_pnl: Broker.d("0")}

    assert {:deny, _, {:drawdown_breaker, {:missing_context, :start_of_day_value}}} =
             Executor.run(executor, intent, lying)

    assert Mode.current(ctx.journal) == :disarmed
    assert Fake.calls(fake, "place_") == []
  end

  test "invalid totals, missing USD currency and invented aliases never become a baseline" do
    for body <- [
          portfolio("-1"),
          portfolio("0"),
          portfolio("NaN"),
          portfolio("Infinity"),
          portfolio("bad"),
          %{"total_value" => "1000", "currency" => "EUR"},
          %{"total_value" => "1000"},
          %{"equity" => "1000", "currency" => "USD"}
        ] do
      fake = Fake.start(portfolio: body)
      {clock, _agent} = Broker.clock(@day)
      ctx = Broker.journal!(clock: clock)
      Broker.capture_baseline!(ctx.journal, fake, clock)
      assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
      assert Broker.records(ctx.path) == []
    end
  end

  test "pin failure and failed reads are denied before any durable capture" do
    for opts <- [
          [account: "OTHER"],
          [faults: [{"get_portfolio", {:http, 403}}]],
          [faults: [{"get_accounts", {:http, 403}}]]
        ] do
      fake = Fake.start(Keyword.put(opts, :portfolio, portfolio("1000")))
      {clock, _agent} = Broker.clock(@day)
      ctx = Broker.journal!(clock: clock)
      Broker.capture_baseline!(ctx.journal, fake, clock)
      assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
      assert Broker.records(ctx.path) == []
    end
  end

  test "the final millisecond is eligible but the window end is not" do
    for {offset, captured?} <- [{59_999, true}, {60_000, false}] do
      now = DateTime.add(@day, offset, :millisecond)
      fake = Fake.start(portfolio: portfolio("1000"))
      ctx = Broker.journal!(clock: fn -> now end)
      Broker.capture_baseline!(ctx.journal, fake, fn -> now end)

      assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) ==
               {:ok, if(captured?, do: Broker.d("1000"), else: nil)}
    end
  end

  test "read failures retry at most three times inside the capture window" do
    fake = Fake.start(portfolio: portfolio("NaN"))
    {clock, agent} = Broker.clock(@day)
    ctx = Broker.journal!(clock: clock)
    owner = self()

    %{worker: worker} =
      Broker.capture_baseline!(ctx.journal, fake, clock,
        schedule: fn delay -> send(owner, {:scheduled, delay}) end
      )

    assert_receive {:scheduled, 1000}

    for seconds <- 1..2 do
      Agent.update(agent, fn _ -> DateTime.add(@day, seconds) end)
      send(worker, :capture)
      assert_receive {:scheduled, delay}, 5_000
      assert delay == if(seconds == 1, do: 1000, else: 86_398_000)
    end

    send(worker, :capture)
    :sys.get_state(worker)
    assert length(Fake.calls(fake, "get_portfolio")) == 3
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
  end

  test "an absent registered read client fails closed with bounded retries" do
    alias Raxol.Broker.DailyBaseline
    {clock, agent} = Broker.clock(@day)
    ctx = Broker.journal!(clock: clock)
    owner = self()

    worker =
      start_supervised!(
        {DailyBaseline,
         journal: ctx.journal,
         account: "FAKE-0001",
         client: :"absent_read_client_#{System.unique_integer([:positive])}",
         clock: clock,
         schedule: fn delay -> send(owner, {:scheduled, delay}) end}
      )

    assert_receive {:scheduled, 1000}

    for seconds <- 1..2 do
      Agent.update(agent, fn _ -> DateTime.add(@day, seconds) end)
      send(worker, :capture)
      assert_receive {:scheduled, delay}, 5_000
      assert delay == if(seconds == 1, do: 1000, else: 86_398_000)
    end

    assert %{attempts: 3, task: nil} = :sys.get_state(worker)
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
    assert Broker.records(ctx.path) == []
  end

  test "a malformed current total never uses the persisted baseline as a live value" do
    for body <- [
          portfolio("-1"),
          portfolio("NaN"),
          %{"equity" => "1000", "currency" => "USD"},
          %{"total_value" => "1000", "currency" => "EUR"}
        ] do
      fake = Fake.start(portfolio: portfolio("1000"))
      ctx = Broker.baseline_journal!(fake)
      Fake.portfolio(fake, body)
      :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

      executor =
        Broker.executor!(ctx.journal, fake,
          policy: Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05"))
        )

      {:ok, intent} =
        Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :strategy)

      assert {:deny, _, {:drawdown_breaker, {:missing_context, :day_pnl}}} =
               Executor.run(executor, intent, %Context{day_pnl: Broker.d("0")})

      assert Fake.calls(fake, "place_") == []
    end
  end

  test "submillisecond and early midnight wakes reschedule and still capture" do
    fake = Fake.start(portfolio: portfolio("1000"))
    {clock, agent} = Broker.clock(DateTime.add(@day, -1001, :microsecond))
    ctx = Broker.journal!(clock: clock)
    owner = self()

    baseline =
      Broker.capture_baseline!(ctx.journal, fake, clock,
        schedule: fn delay -> send(owner, {:scheduled, delay}) end
      )

    assert_receive {:scheduled, 2}

    Agent.update(agent, fn _ -> DateTime.add(@day, -1, :microsecond) end)
    send(baseline.worker, :capture)
    assert_receive {:scheduled, 1}, 5_000
    assert Fake.calls(fake, "get_portfolio") == []

    Agent.update(agent, fn _ -> @day end)
    send(baseline.worker, :capture)
    assert_receive {:scheduled, 86_400_000}, 5_000
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, Broker.d("1000")}
  end

  test "a backwards clock schedules the next boundary from actual current time" do
    fake = Fake.start(portfolio: portfolio("1000"))
    {clock, agent} = Broker.clock(~U[2026-10-02 14:00:00Z])
    ctx = Broker.journal!(clock: clock)
    owner = self()

    baseline =
      Broker.capture_baseline!(ctx.journal, fake, clock,
        schedule: fn delay -> send(owner, {:scheduled, delay}) end
      )

    assert_receive {:scheduled, 50_400_000}

    Agent.update(agent, fn _ -> ~U[2026-10-02 13:00:00Z] end)
    send(baseline.worker, :capture)
    assert_receive {:scheduled, 54_000_000}, 5_000
    assert Fake.calls(fake, "get_portfolio") == []
  end

  test "bad configured clocks cannot crash the collector and a valid clock recovers" do
    for failure <- [:malformed, :raising] do
      {:ok, mode} = Agent.start_link(fn -> failure end)

      clock = fn ->
        case Agent.get(mode, & &1) do
          :malformed -> :not_a_timestamp
          :raising -> raise ArgumentError, "configured clock failed"
          :valid -> @day
        end
      end

      fake = Fake.start(portfolio: portfolio("1000"))
      ctx = Broker.journal!(clock: fn -> @day end)
      owner = self()

      baseline =
        Broker.capture_baseline!(ctx.journal, fake, clock,
          schedule: fn delay -> send(owner, {:scheduled, delay}) end
        )

      assert_receive {:scheduled, 1000}, 5_000
      assert Process.alive?(baseline.worker)
      assert Fake.calls(fake, "get_portfolio") == []
      assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}

      Agent.update(mode, fn _ -> :valid end)
      send(baseline.worker, :capture)
      assert_receive {:scheduled, 86_400_000}, 5_000
      assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, Broker.d("1000")}
    end
  end

  test "next midnight scheduling observes both DST changes" do
    for {now, delay} <- [
          {~U[2026-03-08 05:01:00Z], 82_740_000},
          {~U[2026-11-01 04:01:00Z], 89_940_000}
        ] do
      fake = Fake.start(portfolio: portfolio("1000"))
      ctx = Broker.journal!(clock: fn -> now end)
      owner = self()

      Broker.capture_baseline!(ctx.journal, fake, fn -> now end,
        schedule: fn delay -> send(owner, {:scheduled, delay}) end
      )

      assert_receive {:scheduled, ^delay}

      assert Journal.day_baseline("FAKE-0001", MarketCalendar.day_start(now), ctx.journal) ==
               {:ok, nil}
    end
  end
end

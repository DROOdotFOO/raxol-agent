defmodule Raxol.Broker.Executor.ContextBoundaryTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  test "context fetched across New York midnight cannot use yesterday's baseline" do
    before_midnight = ~U[2026-10-03 03:59:59Z]
    after_midnight = ~U[2026-10-03 04:00:01Z]

    fake =
      Fake.start(
        quotes: %{"AAPL" => "125"},
        portfolio: %{"total_value" => "1000", "currency" => "USD"}
      )

    ctx = Broker.baseline_journal!(fake, before_midnight)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    executor =
      Broker.executor!(ctx.journal, fake,
        clock: ctx.clock,
        policy: Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05"))
      )

    Fake.on_call(fake, "get_portfolio", fn _args ->
      Agent.update(ctx.clock_agent, fn _ -> after_midnight end)
      :answer
    end)

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :strategy)

    assert {:error, {:context, :clock_changed}} = Executor.run(executor, intent, %Context{})
    assert Fake.calls(fake, "review_") == []
    assert Fake.calls(fake, "place_") == []
  end

  test "a context finishing after the regular close uses the completed read's session" do
    before_close = ~U[2026-10-02 19:59:59Z]
    after_close = ~U[2026-10-02 20:00:01Z]

    fake =
      Fake.start(
        quotes: %{"AAPL" => "125"},
        portfolio: %{"total_value" => "1000", "currency" => "USD"}
      )

    ctx = Broker.baseline_journal!(fake, before_close)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    executor =
      Broker.executor!(ctx.journal, fake,
        clock: ctx.clock,
        policy:
          Broker.policy("1000", "5000",
            drawdown_halt: Broker.d("0.05"),
            order_types: [:market, :limit],
            after_hours_market: false
          )
      )

    Fake.on_call(fake, "get_portfolio", fn _args ->
      Agent.update(ctx.clock_agent, fn _ -> after_close end)
      :answer
    end)

    {:ok, intent} = Intent.buy_shares("AAPL", Broker.d("1"), provenance: :strategy)

    assert {:deny, _group, {:after_hours_market, :extended}} =
             Executor.run(executor, intent, %Context{})

    assert Fake.calls(fake, "review_") == []
    assert Fake.calls(fake, "place_") == []
  end

  test "a review finishing after midnight cannot place using yesterday's baseline" do
    before_midnight = ~U[2026-10-03 03:59:59Z]
    after_midnight = ~U[2026-10-03 04:00:01Z]

    fake =
      Fake.start(
        quotes: %{"AAPL" => "125"},
        portfolio: %{"total_value" => "1000", "currency" => "USD"}
      )

    ctx = Broker.baseline_journal!(fake, before_midnight)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    executor =
      Broker.executor!(ctx.journal, fake,
        clock: ctx.clock,
        policy: Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05"))
      )

    Fake.on_call(fake, "review_equity_order", fn _args ->
      Agent.update(ctx.clock_agent, fn _ -> after_midnight end)
      :answer
    end)

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :strategy)

    assert {:error, {:context, :clock_changed}} = Executor.run(executor, intent, %Context{})
    assert Fake.calls(fake, "review_") == ["review_equity_order"]
    assert Fake.calls(fake, "place_") == []
  end

  test "a late review cannot cross a market session or move the clock backwards" do
    for {before_review, after_review} <- [
          {~U[2026-10-02 19:59:59Z], ~U[2026-10-02 20:00:01Z]},
          {~U[2026-10-02 14:30:01Z], ~U[2026-10-02 14:30:00Z]}
        ] do
      fake =
        Fake.start(
          quotes: %{"AAPL" => "125"},
          portfolio: %{"total_value" => "1000", "currency" => "USD"}
        )

      ctx = Broker.baseline_journal!(fake, before_review)
      :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

      executor =
        Broker.executor!(ctx.journal, fake,
          clock: ctx.clock,
          policy:
            Broker.policy("1000", "5000",
              drawdown_halt: Broker.d("0.05"),
              order_types: [:market, :limit],
              after_hours_market: false
            )
        )

      Fake.on_call(fake, "review_equity_order", fn _args ->
        Agent.update(ctx.clock_agent, fn _ -> after_review end)
        :answer
      end)

      {:ok, intent} = Intent.buy_shares("AAPL", Broker.d("1"), provenance: :strategy)

      assert {:error, {:context, :clock_changed}} = Executor.run(executor, intent, %Context{})
      assert Fake.calls(fake, "review_") == ["review_equity_order"]
      assert Fake.calls(fake, "place_") == []
    end
  end

  test "halt interrupts a blocked final placement clock without sending" do
    owner = self()

    fake =
      Fake.start(
        quotes: %{"AAPL" => "125"},
        portfolio: %{"total_value" => "1000", "currency" => "USD"}
      )

    ctx = Broker.baseline_journal!(fake, ~U[2026-10-02 14:30:00Z])
    {:ok, phase} = Agent.start_link(fn -> :before_review end)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    Fake.on_call(fake, "review_equity_order", fn _args ->
      Agent.update(phase, fn _ -> :after_review end)
      :answer
    end)

    clock = fn ->
      if Agent.get(phase, & &1) == :after_review do
        send(owner, {:placement_clock, self()})

        receive do
          :release -> ctx.clock.()
        end
      else
        ctx.clock.()
      end
    end

    executor =
      Broker.executor!(ctx.journal, fake,
        clock: clock,
        policy: Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05"))
      )

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :strategy)

    run = Task.async(fn -> Executor.run(executor, intent, %Context{}) end)
    assert_receive {:placement_clock, callback}
    monitor = Process.monitor(callback)

    assert {:ok, _result} = Executor.halt_orders(executor, 1000)
    assert {:error, :not_armed} = Task.await(run)
    assert_receive {:DOWN, ^monitor, :process, ^callback, :killed}
    assert Fake.calls(fake, "place_") == []
  end
end

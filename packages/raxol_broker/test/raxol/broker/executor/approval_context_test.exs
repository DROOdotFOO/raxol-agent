defmodule Raxol.Broker.Executor.ApprovalContextTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal, Mode}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  defp broker!(policy) do
    fake =
      Fake.start(
        warnings: ["operator review"],
        quotes: %{"AAPL" => "125"},
        positions: [],
        portfolio: %{"total_value" => "1000", "currency" => "USD"}
      )

    ctx = Broker.baseline_journal!(fake)

    executor = Broker.executor!(ctx.journal, fake, policy: policy)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    Map.merge(ctx, %{fake: fake, executor: executor})
  end

  defp ask!(ctx, id) do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("2"), Broker.d("125"), provenance: :strategy, id: id)

    {:ask, group, _} = Executor.run(ctx.executor, intent, %Context{})
    group
  end

  test "approval denies a position weight that changed while parked" do
    ctx = broker!(Broker.policy("1000", "5000", max_position_weight: Broker.d("0.3")))
    group = ask!(ctx, "weight")
    Fake.portfolio(ctx.fake, %{"total_value" => "500", "currency" => "USD"})

    assert {:deny, ^group, {:max_position_weight, _}} =
             Executor.approve(ctx.executor, group, "operator")

    assert Fake.calls(ctx.fake, "place_") == []

    contexts =
      for %{"group_id" => ^group, "type" => "context"} = r <- Broker.records(ctx.path),
          do: r["context"]

    assert Enum.map(contexts, & &1["portfolio_value"]) == ["1000", "500"]
  end

  test "approval drawdown denial disarms and holds the journal pause" do
    ctx = broker!(Broker.policy("1000", "5000", drawdown_halt: Broker.d("0.05")))
    group = ask!(ctx, "drawdown")
    Fake.portfolio(ctx.fake, %{"total_value" => "940", "currency" => "USD"})

    assert {:deny, ^group, {:drawdown_breaker, _}} =
             Executor.approve(ctx.executor, group, "operator")

    assert Mode.current(ctx.journal) == :disarmed
    assert Journal.pauses(ctx.journal) == {:ok, [:drawdown_halt]}
    assert Fake.calls(ctx.fake, "place_") == []
  end

  test "approval fetches a fresh quote and counts the market order at that quote" do
    ctx = broker!(Broker.policy("1000", "5000", order_types: [:market, :limit]))
    {:ok, intent} = Intent.buy_shares("AAPL", Broker.d("2"), provenance: :human, id: "market")
    {:ask, group, _} = Executor.run(ctx.executor, intent, %Context{})

    Fake.on_call(ctx.fake, "get_equity_quotes", fn _ ->
      {:result,
       %{
         "content" => [
           %{
             "type" => "text",
             "text" =>
               Jason.encode!(%{
                 "results" => [
                   %{"quote" => %{"symbol" => "AAPL", "last_trade_price" => "150"}}
                 ]
               })
           }
         ]
       }}
    end)

    assert {:ok, %{status: :placed}} = Executor.approve(ctx.executor, group, "operator")
    assert {:ok, counted} = Journal.today_notional(~U[2026-10-02 04:00:00Z], ctx.journal)
    assert Decimal.equal?(counted, Broker.d("300"))
  end

  test "approval uses its fresh capture time and refuses a session change after capture" do
    before_close = ~U[2026-10-02 19:59:59Z]
    after_close = ~U[2026-10-02 20:00:01Z]

    for crossing <- [:while_parked, :after_fresh_capture] do
      fake =
        Fake.start(
          warnings: ["operator review"],
          quotes: %{"AAPL" => "125"},
          portfolio: %{"total_value" => "1000", "currency" => "USD"}
        )

      ctx = Broker.baseline_journal!(fake, before_close)
      {:ok, times} = Agent.start_link(fn -> [before_close] end)

      clock = fn ->
        Agent.get_and_update(times, fn [at | rest] ->
          {at, if(rest == [], do: [at], else: rest)}
        end)
      end

      executor =
        Broker.executor!(ctx.journal, fake,
          clock: clock,
          policy: Broker.policy("1000", "5000")
        )

      :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
      group = ask!(Map.merge(ctx, %{executor: executor}), "approval-clock")

      case crossing do
        :while_parked ->
          Agent.update(times, fn _ -> [after_close] end)
          assert {:ok, %{status: :placed}} = Executor.approve(executor, group, "operator")
          assert Fake.calls(fake, "place_") == ["place_equity_order"]

        :after_fresh_capture ->
          Agent.update(times, fn _ -> [before_close, before_close, after_close] end)

          assert {:error, {:context, :clock_changed}} =
                   Executor.approve(executor, group, "operator")

          assert Fake.calls(fake, "place_") == []

          assert Enum.any?(Broker.records(ctx.path), fn record ->
                   record["group_id"] == group and record["type"] == "close" and
                     record["reason"] == "clock_changed"
                 end)
      end
    end
  end
end

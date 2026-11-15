defmodule Raxol.Broker.Executor.ApprovalContextTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal, Mode}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  defp broker!(policy) do
    ctx = Broker.journal!()

    fake =
      Fake.start(
        warnings: ["operator review"],
        quotes: %{"AAPL" => "125"},
        positions: [],
        portfolio: %{"equity" => "1000", "adjusted_equity_previous_close" => "1000"}
      )

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
    Fake.portfolio(ctx.fake, %{"equity" => "500", "adjusted_equity_previous_close" => "1000"})

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
    Fake.portfolio(ctx.fake, %{"equity" => "940", "adjusted_equity_previous_close" => "1000"})

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
               Jason.encode!(%{"quotes" => [%{"symbol" => "AAPL", "last_trade_price" => "150"}]})
           }
         ]
       }}
    end)

    assert {:ok, %{status: :placed}} = Executor.approve(ctx.executor, group, "operator")
    assert {:ok, counted} = Journal.today_notional(~U[2026-10-02 04:00:00Z], ctx.journal)
    assert Decimal.equal?(counted, Broker.d("300"))
  end
end

defmodule Raxol.Broker.OrderContractTest do
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker

  alias Raxol.Broker.{Executor, Intent, Journal, Policy}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context

  @moduletag :capture_log
  @priced_kinds [:limit, :stop_limit, :stop_market]

  setup do
    %{journal: journal} = journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, journal)
    fake = Fake.start(quotes: %{"AAPL" => "125"})

    executor =
      executor!(journal, fake,
        policy:
          policy("1000", "5000",
            order_types: [:market, :limit, :stop_limit, :stop_market],
            options: true,
            advanced_orders: true
          )
      )

    %{executor: executor, fake: fake}
  end

  test "limit and stop constructors reject fractional quantities without rounding" do
    for kind <- @priced_kinds, side <- [:buy, :sell], qty <- [d("0.5"), d("1.0001")] do
      assert {:error, {:invalid, :qty, ^qty}} = equity_intent(kind, side, qty)
    end
  end

  test "normalization and public execution refuse forged fractional limit and stop orders", ctx do
    for kind <- @priced_kinds, side <- [:buy, :sell] do
      {:ok, whole} = equity_intent(kind, side, d("2"))
      fractional = %{whole | qty: d("1.5")}

      assert Intent.normalize(fractional) == {:error, {:invalid, :qty}}
      assert Policy.evaluate(fractional, %Context{}) == {:deny, {:intent, {:invalid, :qty}}}

      assert Executor.run(ctx.executor, fractional, %Context{}) ==
               {:error, {:invalid_intent, {:invalid, :qty}}}
    end

    assert_no_order_calls(ctx.fake)
  end

  test "whole-share quantities and approved prices pass through every priced kind unchanged",
       ctx do
    for kind <- @priced_kinds, side <- [:buy, :sell] do
      qty = d("2.00")
      {:ok, intent} = equity_intent(kind, side, qty)
      assert {:ok, ^intent} = Intent.normalize(intent)
      assert {:ok, %{status: :placed}} = Executor.run(ctx.executor, intent, %Context{})
    end

    calls = order_calls(ctx.fake)
    assert length(calls) == 12

    for [{"review_equity_order", review}, {"place_equity_order", place}] <-
          Enum.chunk_every(calls, 2) do
      assert review == Map.delete(place, "ref_id")
      assert review["quantity"] == "2.00"
      assert review["type"] in ["limit", "stop_limit", "stop_market"]

      if Map.has_key?(review, "limit_price"), do: assert(review["limit_price"] == "125.123456")
      if Map.has_key?(review, "stop_price"), do: assert(review["stop_price"] == "126.654321")
    end
  end

  test "integral decimal representations remain accepted without quantity rewriting" do
    for qty <- [d("1"), d("1.000"), d("2E1")], kind <- @priced_kinds do
      assert {:ok, %Intent{qty: ^qty} = intent} = equity_intent(kind, :buy, qty)
      assert {:ok, ^intent} = Intent.normalize(intent)
    end
  end

  test "market fractional and dollar orders retain GFD regular-hours defaults", ctx do
    for {:ok, intent} <- [
          Intent.buy_usd("AAPL", d("100.25"), provenance: :strategy),
          Intent.buy_shares("AAPL", d("0.125"), provenance: :strategy),
          Intent.sell("AAPL", d("0.125"), provenance: :strategy)
        ] do
      assert {:ok, %{status: :placed}} = Executor.run(ctx.executor, intent, %Context{})
    end

    calls = order_calls(ctx.fake)
    assert length(calls) == 6

    for [{"review_equity_order", review}, {"place_equity_order", place}] <-
          Enum.chunk_every(calls, 2) do
      assert review == Map.delete(place, "ref_id")
      assert review["type"] == "market"
      assert Map.get(review, "time_in_force", "gfd") == "gfd"
      assert Map.get(review, "market_hours", "regular_hours") == "regular_hours"
    end

    assert {"review_equity_order", %{"dollar_amount" => "100.25"}} = Enum.at(calls, 0)
    assert {"review_equity_order", %{"quantity" => "0.125"}} = Enum.at(calls, 2)
    assert {"review_equity_order", %{"quantity" => "0.125"}} = Enum.at(calls, 4)
  end

  test "equity adapter overrides cannot turn valid intents into unsupported combinations", ctx do
    {:ok, dollar} = Intent.buy_usd("AAPL", d("100"), provenance: :strategy)
    {:ok, fractional} = Intent.buy_shares("AAPL", d("0.5"), provenance: :strategy)

    for intent <- [dollar, fractional],
        params <- [
          %{"type" => "limit"},
          %{"time_in_force" => "gtc"},
          %{"market_hours" => "extended_hours"},
          %{"market_hours" => "all_day_hours"}
        ] do
      assert Executor.run(ctx.executor, %{intent | params: params}, %Context{}) ==
               {:error, {:invalid_intent, {:invalid, :params}}}
    end

    assert_no_order_calls(ctx.fake)
  end

  test "options remain unreachable even with policy permission and caller-supplied chain proof",
       ctx do
    for hours <- [nil, "regular_hours", "regular_curb_hours", "regular_curb_overnight_hours"] do
      params = %{
        "market_hours" => hours,
        "type" => "limit",
        "price" => "1.01",
        "extended_hours_state" => "enabled"
      }

      {:ok, intent} = Intent.option(:buy, "SPX", d("100"), provenance: :strategy, params: params)
      assert Executor.run(ctx.executor, intent, %Context{}) == {:error, {:no_adapter, :option}}
    end

    assert_no_order_calls(ctx.fake)
    refute "get_option_chains" in Fake.calls(ctx.fake, "get_")
  end

  test "there is no crypto intent or execution path that can round an approved price", ctx do
    {:ok, equity} = Intent.limit(:buy, "BTC-USD", d("1"), d("125.123456"), provenance: :strategy)

    assert Executor.run(ctx.executor, %{equity | kind: :crypto}, %Context{}) ==
             {:error, {:invalid_intent, {:invalid, :kind}}}

    {:ok, advanced} =
      Intent.advanced(:buy, "BTC-USD", d("100"),
        provenance: :strategy,
        params: %{"asset_class" => "crypto", "limit_price" => "125.123456"}
      )

    assert Executor.run(ctx.executor, advanced, %Context{}) == {:error, {:no_adapter, :advanced}}
    assert_no_order_calls(ctx.fake)
    refute "get_currency_pairs" in Fake.calls(ctx.fake, "get_")
  end

  defp equity_intent(kind, side, qty) do
    opts = [provenance: :strategy]

    case kind do
      :limit -> Intent.limit(side, "AAPL", qty, d("125.123456"), opts)
      :stop_limit -> Intent.stop_limit(side, "AAPL", qty, d("126.654321"), d("125.123456"), opts)
      :stop_market -> Intent.stop_market(side, "AAPL", qty, d("126.654321"), opts)
    end
  end

  defp order_calls(fake) do
    Enum.filter(Fake.calls(fake), fn {name, _args} ->
      String.starts_with?(name, ["review_", "preview_", "place_"])
    end)
  end

  defp assert_no_order_calls(fake), do: assert(order_calls(fake) == [])
end

defmodule Raxol.Broker.Strategy.DipBuyTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Intent
  alias Raxol.Broker.Strategy.DipBuy

  defp d(value), do: Decimal.new(value)
  defp q(price), do: %{last: d(price), bid: nil, ask: nil}

  defp model(params \\ %{}) do
    {:ok, model} = DipBuy.init(Map.merge(%{"symbol" => "F", "usd" => "25"}, params))
    model
  end

  defp feed(model, quotes) do
    Enum.reduce(quotes, {model, []}, fn {symbol, price}, {model, emitted} ->
      {model, intents} = DipBuy.update({:quote, symbol, q(price)}, model)
      {model, emitted ++ intents}
    end)
  end

  test "a 2% dip emits one limit buy in whole shares priced at the quote" do
    {_model, [intent]} = feed(model(), [{"F", "10.00"}, {"F", "9.80"}])

    assert %Intent{kind: :limit, side: :buy, symbol: "F", provenance: :strategy} = intent
    assert Decimal.equal?(intent.limit, d("9.80"))
    assert Decimal.equal?(intent.qty, d("2"))
  end

  test "a 1.9% dip emits nothing" do
    assert {_model, []} = feed(model(), [{"F", "10.00"}, {"F", "9.81"}])
  end

  test "a quote for another symbol emits nothing" do
    assert {_model, []} = feed(model(), [{"F", "10.00"}, {"AAPL", "1.00"}])
  end

  test "the reference is the highest price seen, and resets after a buy" do
    {_model, intents} =
      feed(model(), [
        {"F", "10.00"},
        {"F", "10.50"},
        {"F", "10.20"},
        {"F", "10.29"},
        {"F", "10.08"}
      ])

    assert [d("10.20"), d("10.08")] == Enum.map(intents, & &1.limit)
  end

  test "a price above usd buys nothing, since orders are whole shares" do
    assert {_model, []} = feed(model(%{"usd" => "5"}), [{"F", "10.00"}, {"F", "9.00"}])
  end

  test "bad parameters are refused" do
    assert {:error, {:invalid_param, :symbol}} = DipBuy.init(%{"symbol" => "", "usd" => "1"})
    assert {:error, {:invalid_param, :usd}} = DipBuy.init(%{"symbol" => "F", "usd" => "-1"})

    assert {:error, {:invalid_param, :dip}} =
             DipBuy.init(%{"symbol" => "F", "usd" => "1", "dip" => "1"})
  end
end

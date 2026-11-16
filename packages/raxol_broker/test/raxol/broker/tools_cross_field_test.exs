defmodule Raxol.Broker.ToolsCrossFieldTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Tools
  alias Raxol.Broker.Tools.MarketData

  @moduletag :capture_log

  setup do
    fake = Fake.start()
    client = start_supervised!({Client, Fake.client_opts(fake)})
    %{fake: fake, client: client}
  end

  test "index quotes require exactly one nonempty list of nonblank IDs or symbols", ctx do
    tool = "get_index_quotes"

    for args <- [
          %{},
          %{"instrument_ids" => nil},
          %{"symbols" => nil},
          %{"instrument_ids" => []},
          %{"symbols" => []},
          %{"instrument_ids" => [""]},
          %{"symbols" => [" \t"]},
          %{"instrument_ids" => ["index-id", " "]},
          %{"symbols" => ["SPX", ""]},
          %{"instrument_ids" => [nil]},
          %{"symbols" => "SPX"},
          %{"instrument_ids" => ["index-id"], "symbols" => ["SPX"]},
          %{"instrument_ids" => [], "symbols" => ["SPX"]},
          %{"instrument_ids" => ["index-id"], "symbols" => []}
        ] do
      assert {:error, {:invalid_args, ^tool, _errors}} =
               MarketData.get_index_quotes(ctx.client, args)
    end

    assert Fake.calls(ctx.fake) == []
  end

  test "index quotes admit either selection and preserve the supplied arguments", ctx do
    selections = [
      %{"instrument_ids" => ["index-id"]},
      %{"symbols" => ["SPX", "NDX"]},
      %{"instrument_ids" => nil, "symbols" => ["SPX"]},
      %{"instrument_ids" => ["index-id"], "symbols" => nil}
    ]

    for args <- selections do
      # The real Fake records these reads but deliberately has no canned
      # response for them. Its server error proves local validation admitted
      # the request; no response hook or fabricated success is needed.
      assert {:error, %{"code" => -32_603}} = MarketData.get_index_quotes(ctx.client, args)
    end

    assert Fake.calls(ctx.fake) == Enum.map(selections, &{"get_index_quotes", &1})
  end

  test "politician trades reject calls without at least one nonblank filter before sending",
       ctx do
    tool = "get_politician_trades"

    for args <- [
          %{},
          %{"politician_name" => ""},
          %{"equity_symbol" => " \t\n"},
          %{"politician_name" => " ", "equity_symbol" => ""},
          %{"politician_name" => nil},
          %{"equity_symbol" => []}
        ] do
      assert {:error, {:invalid_args, ^tool, _errors}} =
               MarketData.get_politician_trades(ctx.client, args)
    end

    assert Fake.calls(ctx.fake) == []
  end

  test "politician trades admit either filter, both filters, and a nonblank filter beside a blank one",
       ctx do
    filters = [
      %{"politician_name" => "Nancy Pelosi"},
      %{"equity_symbol" => "NVDA"},
      %{"politician_name" => "Nancy Pelosi", "equity_symbol" => "NVDA"},
      %{"politician_name" => " ", "equity_symbol" => " nvda "},
      %{"politician_name" => " Nancy Pelosi ", "equity_symbol" => ""}
    ]

    for args <- filters do
      assert {:error, %{"code" => -32_603}} = MarketData.get_politician_trades(ctx.client, args)
    end

    assert Fake.calls(ctx.fake) == Enum.map(filters, &{"get_politician_trades", &1})
  end

  test "technical indicator exactly-one semantics remain unchanged", ctx do
    tool = "get_equity_technical_indicators"
    keys = ["symbol", "symbols"]
    base = %{"type" => "rsi", "interval" => "day", "start_time" => "2026-11-01T00:00:00Z"}
    refused = {:error, {:invalid_args, tool, [{[], {:exactly_one_of, keys}}]}}

    for selection <- [
          %{},
          %{"symbols" => nil},
          %{"symbol" => "AAPL", "symbols" => ["AAPL"]}
        ] do
      assert Tools.call(ctx.client, tool, Map.merge(base, selection)) == refused
    end

    assert {:error, {:invalid_args, ^tool, [{["symbol"], {:type, "string"}}]}} =
             Tools.call(ctx.client, tool, Map.put(base, "symbol", nil))

    assert Fake.calls(ctx.fake) == []

    for selection <- [%{"symbol" => "AAPL"}, %{"symbols" => ["AAPL"]}] do
      args = Map.merge(base, selection)
      assert {:error, %{"code" => -32_603}} = Tools.call(ctx.client, tool, args)
    end

    assert Fake.calls(ctx.fake, "get_") == [tool, tool]
  end
end

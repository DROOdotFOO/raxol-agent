defmodule Raxol.Web3.FXTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.FXHarness

  alias Raxol.Web3.FX
  alias Raxol.Web3.FX.Chainlink
  alias Raxol.Web3.FX.Quality
  alias Raxol.Web3.MCP.FXTools

  @base_eur Raxol.Web3.FXHarness.base_eur()

  describe "Quality" do
    test "the 100 bps boundary: at it is ok, past it is suspect" do
      at = asset(price_usd: Decimal.new("1.146350"))
      past = asset(price_usd: Decimal.new("1.146464"))

      assert %{status: :ok, deviation_bps: 100} = Quality.judge(at, rates())

      assert %{status: :ok, deviation_bps: -100} =
               Quality.judge(asset(price_usd: Decimal.new("1.12365")), rates())

      assert %{status: :suspect, deviation_bps: 101} = Quality.judge(past, rates())
      assert %{status: :suspect} = Quality.judge(asset(price_usd: Decimal.new("1.1235")), rates())
    end

    test "the line is drawn on the true deviation, not on the rounded one shown" do
      # 100.4, 100.5 and -100.5 bps off a rate of 1.1350. Each rounds to ±100
      # for display, and each is past the line.
      for price <- ~w(1.14639540 1.14640675 1.12359325) do
        assert %{status: :suspect, deviation_bps: shown} =
                 Quality.judge(asset(price_usd: Decimal.new(price)), rates())

        assert abs(shown) == 100
      end
    end

    test "the line is exact past 28 digits and independent of the caller's context" do
      # 1.1350 * 1.01 plus 10^-33: a 34-digit price strictly past 100 bps, which
      # the default 28-digit division rounded back onto the line.
      for price <- ~w(1.146350000000000000000000000000001 1.123649999999999999999999999999999) do
        assert %{status: :suspect} = Quality.judge(asset(price_usd: Decimal.new(price)), rates())
      end

      # 100.0088 bps, under a caller's 6-digit context that trapped inexact
      # results: the verdict neither changes nor raises.
      narrow = %Decimal.Context{precision: 6, rounding: :half_up, traps: [:inexact]}

      verdict =
        Decimal.Context.with(narrow, fn ->
          Quality.judge(asset(price_usd: Decimal.new("1.146351")), rates())
        end)

      assert %{status: :suspect, deviation_bps: 100} = verdict

      assert %{status: :no_rate} =
               Quality.judge(asset([]), %{
                 "EUR" => {:ok, %{rate: Decimal.new(0), precision_bps: 10}}
               })
    end

    test "yield-bearing wins over everything, and gets no deviation" do
      verdict = Quality.judge(asset(yield_bearing?: true, price_usd: Decimal.new("9")), rates())
      assert %{status: :yield_bearing, deviation_bps: nil} = verdict
    end

    test "no usable rate, or no feed at all, is :no_rate" do
      assert %{status: :no_rate} = Quality.judge(asset(peg_currency: "GBP"), rates())
      assert %{status: :no_rate} = Quality.judge(asset([]), %{"EUR" => {:error, :stale}})
    end

    test "an asset with no price cannot be verified, so it is suspect" do
      assert %{status: :suspect, deviation_bps: nil} =
               Quality.judge(asset(price_usd: nil), rates())
    end
  end

  describe "FX, end to end on the recorded data" do
    test "every asset carries our verdict, and the known outliers land where they should" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_deviation")})
      fx = FX.new(s, chainlink())

      assert {:ok, %{assets: assets}} = FX.stables(fx, sort: "deviationBps", limit: 6)
      by_symbol = Map.new(assets, &{&1.symbol, &1.quality})

      # REUR: a fiat-backed EUR token priced at $4.13.
      assert %{status: :suspect} = by_symbol["REUR"]
      assert %{status: :yield_bearing} = by_symbol["USDY"]
    end

    test "the partner set judges ok against Chainlink, not against Sleuth's stale rates" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      assert {:ok, %{assets: assets}} = FX.stables(FX.new(s, chainlink()), partner_only: true)

      for %{symbol: symbol, quality: quality} <- assets do
        assert quality.status == :ok, "#{symbol}: #{inspect(quality)}"
      end
    end
  end

  describe "MCP tools" do
    defp tool(fx, name), do: Enum.find(FXTools.tool_defs(fx), &(&1.name == name))

    test "every tool is prefixed web3_fx_, read-only and sensitive" do
      fx = FX.new(sleuth(%{}), chainlink())

      for %{name: name, annotations: annotations} <- FXTools.tool_defs(fx) do
        assert String.starts_with?(name, "web3_fx_")
        assert annotations == %{readOnlyHint: true, sensitive: true}
      end
    end

    test "a result is JSON with string figures and our verdict on every asset" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      stables = tool(FX.new(s, chainlink()), "web3_fx_stables")

      assert {:ok, result} = stables.callback.(%{"partner_only" => true})
      decoded = result |> Jason.encode!() |> Jason.decode!()

      eure = Enum.find(decoded["assets"], &(&1["symbol"] == "EURe"))
      assert is_binary(eure["price_usd"])
      assert %{"status" => "ok", "rate" => rate, "deviation_bps" => bps} = eure["quality"]
      assert is_binary(rate) and is_integer(bps)
    end

    test "bad arguments answer a closed error code and send nothing" do
      fx = FX.new(sleuth(%{}), chainlink())

      assert {:error, %{code: "invalid_argument", detail: "limit"}} =
               tool(fx, "web3_fx_stables").callback.(%{"limit" => 9_999})

      assert {:error, %{code: "missing_argument", detail: "symbol"}} =
               tool(fx, "web3_fx_stable").callback.(%{})

      assert {:error, %{code: "invalid_argument", detail: "include_assets"}} =
               tool(fx, "web3_fx_corridors").callback.(%{"include_assets" => "yes"})

      refute_received {:request, _}
    end

    test "an upstream refusal is not counted against the tool unless it is a fault" do
      s = sleuth(%{"/api/mcp/fx/stables/NOPE" => {404, ~s({"error":"x"})}})
      stable = tool(FX.new(s, chainlink()), "web3_fx_stable")

      assert {:error, error} = stable.callback.(%{"symbol" => "NOPE"})
      refute stable.fault?.(error)
      assert stable.fault?.(%{code: "upstream_refused", detail: :auth})
    end

    test "a 403 is a status, not a bad key, and counts as a fault of the source" do
      s = sleuth(%{"/api/mcp/fx/stables" => {403, "<html>challenge</html>"}})
      stables = tool(FX.new(s, chainlink()), "web3_fx_stables")

      assert {:error, %{code: "http", detail: 403} = error} = stables.callback.(%{})
      assert stables.fault?.(error)
    end
  end

  describe "price_fn/3" do
    # What `Raxol.Payments.Prices.FX` passes: `Raxol.Payments.Assets.fx_pegs/0`.
    @pegs %{"EURC" => "EUR", "EURe" => "EUR", "ZCHF" => "CHF"}

    defp fallback do
      fn
        "ETH" -> Decimal.new("2500")
        _ -> nil
      end
    end

    # `priceUsd` as a JSON number, as Sleuth sends it; a string decodes to nil.
    defp snapshot(assets),
      do:
        Jason.encode!(%{
          assets: Enum.map(assets, &Map.update!(&1, :priceUsd, fn p -> Jason.Fragment.new(p) end))
        })

    test "EUR and CHF stables price at the Chainlink rate; everything else falls back" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      fx = FX.new(s, chainlink())
      {:ok, eur} = Chainlink.rate(fx.chainlink, "EUR")
      {:ok, chf} = Chainlink.rate(fx.chainlink, "CHF")

      price = FX.price_fn(fx, @pegs, fallback())

      assert price.("EURe") == eur.rate
      assert price.("EURC") == eur.rate
      assert price.("ZCHF") == chf.rate
      assert price.("ETH") == Decimal.new("2500")
      # Dollar stables are the ledger's own business (usdc_price), not ours.
      assert price.("USDT") == nil

      # One snapshot at build time, none per lookup.
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "Sleuth's labels choose neither the symbols repriced nor the peg" do
      {:ok, eur} = Chainlink.rate(chainlink(), "EUR")
      {:ok, chf} = Chainlink.rate(chainlink(), "CHF")
      at_eur = Decimal.to_string(eur.rate)

      body =
        snapshot([
          # A symbol nobody registered, labelled as a euro stable at the EUR rate.
          %{symbol: "ETH", pegCurrency: "EUR", priceUsd: at_eur, partner: true},
          # ZCHF relabelled EUR and priced at the EUR rate.
          %{symbol: "FRANKENCOIN", pegCurrency: "EUR", priceUsd: at_eur, partner: true},
          # EURC relabelled CHF, at a price that is right for EUR.
          %{symbol: "EURC", pegCurrency: "CHF", priceUsd: at_eur, partner: true}
        ])

      s = sleuth(%{"/api/mcp/fx/stables" => body})
      price = FX.price_fn(FX.new(s, chainlink()), @pegs, fallback())

      assert price.("ETH") == Decimal.new("2500")
      # Judged against CHF, its registered peg: the EUR rate is far off it.
      assert price.("ZCHF") == nil
      refute price.("ZCHF") == chf.rate
      # A peg Sleuth disagrees with is a veto, never a different rate.
      assert price.("EURC") == nil
      # Registered but absent from the snapshot: nil, not the fallback.
      assert price.("EURe") == nil
    end

    test "a symbol listed twice is priced only if every listing is ok" do
      {:ok, eur} = Chainlink.rate(chainlink(), "EUR")

      body =
        snapshot([
          %{symbol: "EURC", pegCurrency: "EUR", priceUsd: "4.13"},
          %{symbol: "EURC", pegCurrency: "EUR", priceUsd: Decimal.to_string(eur.rate)}
        ])

      s = sleuth(%{"/api/mcp/fx/stables" => body})
      assert FX.price_fn(FX.new(s, chainlink()), @pegs, fallback()).("EURC") == nil
    end

    test "symbol case decides neither which listings veto nor what reaches the fallback" do
      {:ok, eur} = Chainlink.rate(chainlink(), "EUR")

      body =
        snapshot([
          %{symbol: "EURC", pegCurrency: "EUR", priceUsd: Decimal.to_string(eur.rate)},
          %{symbol: "eurc", pegCurrency: "EUR", priceUsd: "0.50"},
          %{symbol: "EURe", pegCurrency: "EUR", priceUsd: Decimal.to_string(eur.rate)}
        ])

      s = sleuth(%{"/api/mcp/fx/stables" => body})
      price = FX.price_fn(FX.new(s, chainlink()), @pegs, fn _ -> Decimal.new(1) end)

      # The lowercase listing at $0.50 vetoes EURC however it is asked for.
      assert price.("EURC") == nil
      assert price.("eurc") == nil
      # Any casing of a registered symbol is answered here, never at par.
      assert price.("EURE") == eur.rate
      assert price.("eure") == eur.rate
      assert price.("zchf") == nil
      assert price.("WETH") == Decimal.new(1)
    end

    # Each test here uses its own RPC URLs: the last logged state is kept per
    # set of URLs, across price functions, as an accounting sweep rebuilds one.
    defp own_urls do
      host = "https://rpc-#{System.unique_integer([:positive])}.test"
      %{1 => "#{host}/eth", 8453 => "#{host}/base"}
    end

    defp build_logged(s, chainlink) do
      ExUnit.CaptureLog.with_log([level: :info], fn ->
        FX.price_fn(FX.new(s, chainlink), @pegs, fallback())
      end)
    end

    test "a peg with no usable rate says why, at warning when refused, once per change" do
      wrong = %{{8453, @base_eur, "0x7284e416"} => feed("chf_usd_ethereum")["description"]}
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      urls = own_urls()

      {price, log} = build_logged(s, chainlink(overrides: wrong, rpc_urls: urls))
      assert price.("EURe") == nil
      assert log =~ ~r/\[warning\].*FX rate for EUR refused.*feed_mismatch/

      # The next sweep, same state: nothing new to say.
      {_price, again} = build_logged(s, chainlink(overrides: wrong, rpc_urls: urls))
      refute again =~ "FX rate for EUR"

      # Recovered.
      {_price, back} = build_logged(s, chainlink(rpc_urls: urls))
      assert back =~ ~r/\[info\].*FX rate for EUR read from its primary feed again/
    end

    test "a rate served by the fallback feed says why the primary was passed over" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})

      urls = %{
        own_urls()
        | 8453 => "https://rpc-#{System.unique_integer([:positive])}.test/elsewhere"
      }

      {price, log} = build_logged(s, chainlink(rpc_urls: urls))
      {:ok, eur} = Chainlink.rate(chainlink(rpc_urls: urls), "EUR")

      assert %{source: {1, _}, fallback_from: {:decode_failed, :identity}} = eur
      assert price.("EURe") == eur.rate

      assert log =~
               ~r/\[info\].*FX rate for EUR from a fallback feed; primary failed.*decode_failed/
    end

    test "a non-ok EUR asset is nil and never falls through to the fallback" do
      s = sleuth(%{"/api/mcp/fx/stables" => sleuth_fixture("stables_partner")})
      price = FX.price_fn(FX.new(s, chainlink(rpc_urls: %{})), @pegs, fn _ -> Decimal.new(1) end)

      assert price.("EURe") == nil
      assert price.("WETH") == Decimal.new(1)
    end

    test "a failed snapshot leaves the registered symbols unpriced and the rest to the fallback" do
      s = sleuth(%{"/api/mcp/fx/stables" => {401, "{}"}})

      price =
        ExUnit.CaptureLog.with_log(fn ->
          FX.price_fn(FX.new(s, chainlink()), @pegs, fn _ -> :fallback end)
        end)
        |> elem(0)

      assert price.("EURe") == nil
      assert price.("ZCHF") == nil
      assert price.("ETH") == :fallback
    end
  end
end

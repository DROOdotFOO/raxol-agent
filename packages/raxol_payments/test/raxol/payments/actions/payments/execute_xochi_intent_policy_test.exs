defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntentPolicyTest do
  use Raxol.Payments.Test.ExecuteXochiIntentCase, async: true

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.Failure
  alias Raxol.Payments.Ledger
  alias Raxol.Payments.Prices.Static
  alias Raxol.Payments.Req.AutoPay
  alias Raxol.Payments.Test.XochiIntentFixture

  # `amount` is a human amount of `from_token`; the gate converts it into the
  # policy's unit (USD here) before it reserves anything or the wallet signs.
  describe "ExecuteXochiIntent policy unit" do
    @weth_base "0x4200000000000000000000000000000000000006"

    defp usd_policy do
      policy(%{
        per_request_max: Decimal.new("10"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("100"),
        approved_domains: ["xochi.test", "api.example.com"]
      })
    end

    defp weth_ctx(ledger, extra \\ %{}) do
      Map.merge(
        %{
          wallet: SpyWallet,
          xochi_config: config(),
          ledger: ledger,
          policy: usd_policy(),
          agent_id: "a1",
          price_fn: Static.price_fn(%{"WETH" => "3000"})
        },
        extra
      )
    end

    defp weth_params(amount), do: base_params(%{amount: amount, from_token: @weth_base})

    test "5 WETH at $3,000 is refused against a $10 per-request cap and nothing is signed" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      assert {:error, %Failure{reason: :over_budget, detail: {:over_budget, :per_request}}} =
               ExecuteXochiIntent.run(weth_params("5"), weth_ctx(ledger))

      refute_received :wallet_signed
      assert Ledger.get_history(ledger, "a1") == []
    end

    test "0.002 WETH at $3,000 is signed and recorded as 6 USD" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      assert {:ok, result} = ExecuteXochiIntent.run(weth_params("0.002"), weth_ctx(ledger))
      # 0.002 WETH at 18 decimals.
      assert result.from_amount == "2000000000000000"
      assert_received :wallet_signed

      assert [%{amount: amount, metadata: metadata}] = Ledger.get_history(ledger, "a1")
      assert Decimal.equal?(amount, Decimal.new("6"))
      assert metadata.protocol == :xochi
      assert metadata.source_asset == {:token, 8453, @weth_base}
      assert Decimal.equal?(metadata.source_amount, Decimal.new("0.002"))
    end

    test "a WETH intent with no price source is refused before signing" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      ctx = Map.delete(weth_ctx(ledger), :price_fn)

      assert {:error,
              %Failure{
                reason: :invalid_request,
                detail: {:unpriced_asset, %{reason: :no_price_source, unit: "USD"}}
              }} = ExecuteXochiIntent.run(weth_params("0.002"), ctx)

      refute_received :wallet_signed
      assert Ledger.get_history(ledger, "a1") == []
    end

    test "a stale WETH price is refused before signing" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      stale = Static.price_fn(%{"WETH" => "3000"}, as_of: System.system_time(:second) - 3600)

      assert {:error, %Failure{detail: {:unpriced_asset, %{reason: :no_price}}}} =
               ExecuteXochiIntent.run(weth_params("0.002"), weth_ctx(ledger, %{price_fn: stale}))

      refute_received :wallet_signed
    end

    test "a price source error refuses the intent before signing" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      failing = fn _symbol -> raise "price feed down" end

      assert {:error,
              %Failure{
                retryable?: true,
                detail: {:unpriced_asset, %{reason: :price_source_error}}
              }} =
               ExecuteXochiIntent.run(
                 weth_params("0.002"),
                 weth_ctx(ledger, %{price_fn: failing})
               )

      refute_received :wallet_signed
    end

    test "USDC counts at par with no price source" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      ctx = Map.delete(weth_ctx(ledger), :price_fn)

      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert [%{amount: amount}] = Ledger.get_history(ledger, "a1")
      assert Decimal.equal?(amount, Decimal.new("0.50"))
    end

    test "a EUR policy refuses a USDC intent before signing" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      ctx = weth_ctx(ledger, %{policy: %{usd_policy() | currency: "EUR"}})

      assert {:error,
              %Failure{
                detail: {:unpriced_asset, %{reason: :fx_unsupported, peg: "USD", unit: "EUR"}}
              }} = ExecuteXochiIntent.run(base_params(%{}), ctx)

      refute_received :wallet_signed
    end

    test "AutoPay x402 and Xochi spends add up against one session_max in USD" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      ctx = weth_ctx(ledger)

      # $4 of USDC through x402, then $6 of WETH through Xochi: the $10 session
      # is exactly spent.
      assert %Req.Response{status: 200} = autopay_get(ledger, "4000000")
      assert {:ok, _} = ExecuteXochiIntent.run(weth_params("0.002"), ctx)

      totals = Ledger.get_totals(ledger, "a1", usd_policy())
      assert Decimal.equal?(totals.session, Decimal.new("10"))

      # Neither path can spend past it: $0.30 of WETH, then $0.01 of USDC.
      assert {:error, %Failure{detail: {:over_budget, :session}}} =
               ExecuteXochiIntent.run(weth_params("0.0001"), ctx)

      assert %Req.Response{body: %{error: :budget_exceeded, limit: :session}} =
               autopay_get(ledger, "10000")

      totals = Ledger.get_totals(ledger, "a1", usd_policy())
      assert Decimal.equal?(totals.session, Decimal.new("10"))
    end

    defp autopay_get(ledger, atomic_usdc) do
      challenge =
        %{
          "maxAmountRequired" => atomic_usdc,
          "payTo" => "0x" <> String.duplicate("cd", 20),
          "asset" => usdc_base(),
          "network" => "eip155:8453",
          "nonce" => "0x" <> String.duplicate("12", 32),
          "validAfter" => 0,
          "validBefore" => System.system_time(:second) + 300
        }
        |> Jason.encode!()
        |> Base.encode64()

      stub = fn req ->
        resp =
          if Req.Request.get_header(req, "x-payment") == [] do
            Req.Response.new(status: 402, body: "")
            |> Req.Response.put_header("payment-required", challenge)
          else
            Req.Response.new(status: 200, body: "ok")
          end

        {req, resp}
      end

      Req.new(url: "https://api.example.com/data", retry: false)
      |> AutoPay.attach(wallet: SpyWallet, ledger: ledger, policy: usd_policy(), agent_id: "a1")
      |> Req.Request.prepend_request_steps(stub: stub)
      |> Req.request!()
    end
  end

  # A hostile or compromised quote endpoint can serve a punitive toAmount
  # (deliver ~0 while pulling the full origin amount); the spend gate sees only
  # the human amount leaving the wallet, not what arrives. The Action floors the
  # delivery before signing: an explicit min_to_amount for any corridor, plus an
  # automatic 80%-of-par floor for same-asset corridors.
  describe "ExecuteXochiIntent delivery floor" do
    @weth_arb "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"
    @eure_arb "0x0c06cCF38114ddfc35e07427B9424adcca9F44F8"

    defp floor_ctx do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      }
    end

    # Base USDC -> Arbitrum USDC: a same-asset corridor, so the automatic floor
    # applies. toAmount (served and signed alike) is configurable to model a
    # punitive quote; `opts` go to `serve_quote/2`.
    defp stub_floor_quote(to_amount, opts \\ []) do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn, Keyword.put(opts, :to_amount, to_amount))

          "/api/intent/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing"
            })
        end
      end)
    end

    defp floor_params(overrides \\ %{}) do
      Map.merge(
        %{
          amount: "1.00",
          from_chain_id: 8453,
          to_chain_id: 42_161,
          from_token: usdc_base(),
          to_token: usdc_arb(),
          settlement: "public"
        },
        overrides
      )
    end

    test "rejects a punitive quote that delivers below the 80% floor, before signing" do
      # 1.00 USDC sent -> par 1_000_000, floor 800_000. Delivering 0.10 USDC
      # (100_000) is a near-total skim and must be refused before signing.
      stub_floor_quote("100000")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteXochiIntent.run(floor_params(), floor_ctx())

      refute_received :wallet_signed
    end

    test "allows a quote that delivers within the floor" do
      # 0.995 USDC delivered on a 1.00 send: a normal fee, well above the floor.
      stub_floor_quote("995000")

      assert {:ok, result} = ExecuteXochiIntent.run(floor_params(), floor_ctx())
      assert result.status == "executing"
      assert_received :wallet_signed
    end

    test "an unparseable toAmount on a same-asset corridor fails closed" do
      # Served and signed alike, so nothing can compare it: refused as an
      # intent that does not bind the quoted delivery, before signing.
      stub_floor_quote("not-a-number")

      assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, :quoted_to_amount}}} =
               ExecuteXochiIntent.run(floor_params(), floor_ctx())

      refute_received :wallet_signed
    end

    test "an explicit min_to_amount is enforced and rejects a quote below it" do
      # 0.90 USDC clears the auto floor (>= 0.80) but is below the caller's
      # explicit 0.95 minimum.
      stub_floor_quote("900000")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), floor_ctx())

      refute_received :wallet_signed
    end

    test "an explicit min_to_amount allows a quote at or above it" do
      stub_floor_quote("960000")

      assert {:ok, _} =
               ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), floor_ctx())

      assert_received :wallet_signed
    end

    test "a min_to_amount below the auto floor cannot lower it on a same-asset corridor" do
      # min_to_amount "1" must not replace the 800_000 floor: a 0.10 USDC
      # delivery on a 1.00 send is still a skim.
      stub_floor_quote("100000")

      assert {:error,
              %Failure{
                reason: :delivery_below_floor,
                detail: {:delivery_below_floor, %{floor: 800_000}}
              }} = ExecuteXochiIntent.run(floor_params(%{min_to_amount: "1"}), floor_ctx())

      refute_received :wallet_signed
    end

    test "a quote is judged on the toAmount the wallet would sign, read as the encoder reads it" do
      # Each served toAmount clears the floor; the signed field does not. Null
      # and missing are encoded as 0, and 2^256 + 1 would sign as its low
      # 256 bits, i.e. 1. None binds the served amount, so each is refused.
      context = floor_ctx()

      for signed <- ["1", nil, Integer.to_string(Integer.pow(2, 256) + 1)] do
        stub_floor_quote("960000", message: %{"toAmount" => signed})

        assert {:error,
                %Failure{reason: :rejected, detail: {:intent_mismatch, :quoted_to_amount}}} =
                 ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), context)

        refute_received :wallet_signed
      end

      # A struct that does not declare toAmount would sign no delivery at all.
      types =
        Map.update!(XochiIntentFixture.types(), "XochiIntent", fn fields ->
          Enum.reject(fields, &(&1["name"] == "toAmount"))
        end)

      stub_floor_quote("960000", types: types)

      assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, :intent_type}}} =
               ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), context)

      refute_received :wallet_signed
    end

    test "a signed toAmount below the floor is refused before signing, whatever is served" do
      # The served toAmount is honest; only the signed one is punitive.
      stub_floor_quote("995000", signed_to_amount: "1")
      ledger = start_supervised!({Ledger, [name: nil]})

      context = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, :quoted_to_amount}}} =
               ExecuteXochiIntent.run(floor_params(), context)

      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "a high stated minimum does not hide a low toAmount" do
      stub_floor_quote("1", extra: %{"minToAmount" => "960000"})

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), floor_ctx())

      refute_received :wallet_signed
    end

    test "a cross-asset corridor with no min_to_amount skips the auto floor" do
      # USDC -> WETH is not a same-asset corridor and has no on-client price, so
      # the auto floor does not apply; a tiny toAmount is trusted unless
      # min_to_amount is given. (It would be rejected if a floor applied.)
      stub_floor_quote("1")

      assert {:ok, _} =
               ExecuteXochiIntent.run(floor_params(%{to_token: @weth_arb}), floor_ctx())

      assert_received :wallet_signed
    end

    test "a zero or unparseable min_to_amount is refused, not treated as no floor" do
      stub_floor_quote("1")
      ctx = floor_ctx()

      for bad <- ["0", 0, "-5", "abc"] do
        assert {:error,
                %Failure{reason: :invalid_request, detail: {:invalid_min_to_amount, ^bad}}} =
                 ExecuteXochiIntent.run(floor_params(%{min_to_amount: bad}), ctx)
      end

      refute_received :wallet_signed
    end

    test "a non-USD destination with no min_to_amount is refused before signing" do
      # USDC -> EURe is cross-asset AND cross-currency: without an FX rate there
      # is no floor to derive, so a punitive toAmount must not be trusted.
      stub_floor_quote("1")

      assert {:error,
              %Failure{
                reason: :invalid_request,
                detail: {:unpriced_asset, %{side: :destination, chain_id: 42_161, peg: "EUR"}}
              }} = ExecuteXochiIntent.run(floor_params(%{to_token: @eure_arb}), floor_ctx())

      refute_received :wallet_signed
    end

    test "a zero min_to_amount bounds nothing, so a non-USD destination is still refused" do
      stub_floor_quote("1")

      assert {:error, %Failure{reason: :invalid_request, detail: {:invalid_min_to_amount, " 0 "}}} =
               ExecuteXochiIntent.run(
                 floor_params(%{to_token: @eure_arb, min_to_amount: " 0 "}),
                 floor_ctx()
               )

      refute_received :wallet_signed
    end

    test "a non-USD destination is allowed once min_to_amount bounds it" do
      stub_floor_quote("960000000000000000")

      assert {:ok, _} =
               ExecuteXochiIntent.run(
                 floor_params(%{to_token: @eure_arb, min_to_amount: "950000000000000000"}),
                 floor_ctx()
               )

      assert_received :wallet_signed
    end

    test "a min_to_amount that is not an integer of atomic units is refused, not ignored" do
      # A garbled floor used to read as absent: the 80% auto floor here, and no
      # floor at all on a cross-asset corridor. It is the caller's bound.
      stub_floor_quote("960000")
      context = floor_ctx()

      for floor <- ["1e6", "950000.0", "-1", "abc"] do
        assert {:error,
                %Failure{reason: :invalid_request, detail: {:invalid_min_to_amount, ^floor}}} =
                 ExecuteXochiIntent.run(floor_params(%{min_to_amount: floor}), context)
      end

      refute_received :wallet_signed
    end

    test "a floor in the source's units on a non-USD destination is refused before signing" do
      stub_floor_quote("960000000000000000")

      assert {:error, %Failure{detail: {:implausible_min_to_amount, _}}} =
               ExecuteXochiIntent.run(
                 floor_params(%{to_token: @eure_arb, min_to_amount: "950000"}),
                 floor_ctx()
               )

      refute_received :wallet_signed
    end
  end
end

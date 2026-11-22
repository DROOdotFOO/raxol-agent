defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntentTest do
  use Raxol.Payments.Test.ExecuteXochiIntentCase, async: true

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Failure
  alias Raxol.Payments.Ledger
  alias Raxol.Payments.Prices.Static
  alias Raxol.Payments.Test.XochiIntentFixture

  describe "ExecuteXochiIntent happy path" do
    test "quotes, gates on human amount, signs, executes, returns intent" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.status == "executing"
      # 0.50 USDC at 6 decimals -> 500000 atomic units
      assert result.from_amount == "500000"
      assert result.to_amount == "499000"
      assert result.stealth_address == "0xstealth"

      assert_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end
  end

  describe "ExecuteXochiIntent stealth keys" do
    test "sends the recipient's compressed pub keys on the quote request" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing",
              "stealthAddress" => "0xstealth"
            })
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, _result} = ExecuteXochiIntent.run(base_params(%{}), ctx)

      assert_received {:quote_body, body}
      assert body["settlement_preference"] == "stealth"

      assert Regex.match?(
               ~r/^0x0[23][a-f0-9]{64}$/,
               body["stealth_spending_pub_key"]
             )

      assert Regex.match?(
               ~r/^0x0[23][a-f0-9]{64}$/,
               body["stealth_viewing_pub_key"]
             )
    end

    test "errors when stealth settlement has no recipient meta-address" do
      ctx = %{wallet: SpyWallet, xochi_config: config()}

      assert {:error, %Failure{reason: :stealth_keys_required}} =
               ExecuteXochiIntent.run(
                 base_params(%{recipient_meta_address: nil}),
                 ctx
               )

      refute_received :wallet_signed
    end
  end

  describe "ExecuteXochiIntent recipient_address" do
    test "sends recipient_address on the quote request for a public transfer" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing"
            })
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      recipient = "0x2222222222222222222222222222222222222222"

      params =
        base_params(%{
          settlement: "public",
          recipient_meta_address: nil,
          recipient_address: recipient
        })

      assert {:ok, _result} = ExecuteXochiIntent.run(params, ctx)

      assert_received {:quote_body, body}
      assert body["recipient_address"] == recipient
      assert body["settlement_preference"] == "public"
    end

    test "two public transfers differing only by recipient are distinct payments" do
      # A payment to recipient B must never resume recipient A's checkpoint --
      # otherwise B's funds would follow A's already-signed intent. The recipient
      # is part of the derived idempotency key, so each signs independently.
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store
      }

      pub = fn recipient ->
        base_params(%{
          settlement: "public",
          recipient_meta_address: nil,
          recipient_address: recipient
        })
      end

      assert {:ok, _} =
               ExecuteXochiIntent.run(pub.("0x2222222222222222222222222222222222222222"), ctx)

      assert_received :wallet_signed

      assert {:ok, _} =
               ExecuteXochiIntent.run(pub.("0x3333333333333333333333333333333333333333"), ctx)

      # Signed a SECOND time -- recipient B was not resumed as recipient A's payment.
      assert_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("1.00"))
    end
  end

  # The served intent is what the wallet signs; a quote whose signed terms differ
  # from the request must be refused before any budget is reserved or anything
  # is signed.
  describe "ExecuteXochiIntent intent binding" do
    @other "0x9999999999999999999999999999999999999999"

    defp binding_ctx(ledger) do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }
    end

    defp public_params(overrides \\ %{}) do
      base_params(
        Map.merge(
          %{
            settlement: "public",
            recipient_meta_address: nil,
            recipient_address: "0x2222222222222222222222222222222222222222"
          },
          overrides
        )
      )
    end

    defp stub_hostile_quote(message) do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" -> serve_quote(conn, message: message)
          "/api/intent/execute" -> flunk("a mismatched intent must never be executed")
        end
      end)
    end

    for {field, message} <- [
          recipient: %{"recipient" => @other},
          to_token: %{"toToken" => @other}
        ] do
      test "a signed #{field} that differs from the request is refused unsigned and unreserved" do
        stub_hostile_quote(unquote(Macro.escape(message)))
        ledger = start_supervised!({Ledger, [name: nil]})

        assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, unquote(field)}}} =
                 ExecuteXochiIntent.run(public_params(), binding_ctx(ledger))

        refute_received :wallet_signed
        totals = Ledger.get_totals(ledger, "a1", policy())
        assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
      end
    end

    test "a mismatched re-quote after expiry is refused and releases the reservation" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            n = Process.get(:quote_calls, 0)
            Process.put(:quote_calls, n + 1)

            if n == 0,
              do: serve_quote(conn),
              else: serve_quote(conn, quote_id: "q_1b", message: %{"recipient" => @other})

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(409, Jason.encode!(%{"error" => "quote_expired"}))
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, :recipient}}} =
               ExecuteXochiIntent.run(public_params(), binding_ctx(ledger))

      # Only the first (honest) quote was signed.
      assert_received :wallet_signed
      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "ExecuteXochiIntent exact_output" do
    defp stub_exact_output(opts) do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn, opts)

          "/api/intent/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing"
            })
        end
      end)
    end

    # Deliver exactly 0.99 USDC, spending at most 1.00.
    defp exact_output_params(overrides \\ %{}) do
      base_params(
        Map.merge(
          %{
            amount: "1.00",
            settlement: "public",
            recipient_meta_address: nil,
            swap_kind: "exact_output",
            output_amount: "990000"
          },
          overrides
        )
      )
    end

    defp exact_ctx(ledger) do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }
    end

    test "asks for the output, reports the signed origin amount, gates on the max spend" do
      stub_exact_output(from_amount: "995000")
      ledger = start_supervised!({Ledger, [name: nil]})

      assert {:ok, result} = ExecuteXochiIntent.run(exact_output_params(), exact_ctx(ledger))

      assert_received {:quote_body, body}
      assert body["swap_kind"] == "exact_output"
      assert body["output_amount"] == "990000"
      refute Map.has_key?(body, "from_amount")
      refute Map.has_key?(body, "max_from_amount")

      assert result.from_amount == "995000"
      assert result.to_amount == "990000"
      assert_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("1.00"))
    end

    test "a signed toAmount other than the requested output is refused" do
      stub_exact_output(from_amount: "995000", to_amount: "980000")
      ledger = start_supervised!({Ledger, [name: nil]})

      assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, :to_amount}}} =
               ExecuteXochiIntent.run(exact_output_params(), exact_ctx(ledger))

      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "a signed fromAmount above the max spend is refused" do
      stub_exact_output(from_amount: "1000001")
      ledger = start_supervised!({Ledger, [name: nil]})

      assert {:error, %Failure{reason: :rejected, detail: {:intent_mismatch, :from_amount}}} =
               ExecuteXochiIntent.run(exact_output_params(), exact_ctx(ledger))

      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "an unknown swap_kind is refused as an invalid request" do
      assert {:error,
              %Failure{reason: :invalid_request, detail: {:invalid_swap_kind, "exact_both"}}} =
               ExecuteXochiIntent.run(
                 exact_output_params(%{swap_kind: "exact_both"}),
                 %{wallet: SpyWallet, xochi_config: config()}
               )

      refute_received :wallet_signed
    end
  end

  describe "ExecuteXochiIntent spend gate" do
    test "denies over per_request and never signs" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(%{per_request_max: Decimal.new("0.10")}),
        agent_id: "a1"
      }

      assert {:error, %Failure{reason: :over_budget}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      refute_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "ExecuteXochiIntent routing" do
    test "rejects a same-chain public transfer that does not route to Xochi" do
      ctx = %{wallet: SpyWallet, xochi_config: config()}

      params =
        base_params(%{to_chain_id: 8453, settlement: "public"})

      assert {:error, %Failure{reason: :route_unsupported}} =
               ExecuteXochiIntent.run(params, ctx)
    end

    test "refuses a Tron leg: chain-aware routing sends it to Relay, not Xochi" do
      ctx = %{wallet: SpyWallet, xochi_config: config()}

      params =
        base_params(%{
          to_chain_id: 728_126_428,
          to_token: usdt_tron(),
          settlement: "public"
        })

      assert {:error, %Failure{reason: :route_unsupported, detail: {:not_xochi_route, :relay}}} =
               ExecuteXochiIntent.run(params, ctx)

      refute_received :wallet_signed
    end

    test "errors when wallet is missing" do
      assert {:error, %Failure{reason: :config_error}} =
               ExecuteXochiIntent.run(base_params(%{}), %{
                 xochi_config: config()
               })
    end
  end

  # A chain/token this build does not know must be refused, never assumed EVM
  # or 6-decimal. 999_999 is a synthetic chain id nothing registers.
  describe "ExecuteXochiIntent unknown chains" do
    @unknown_chain 999_999

    test "an unregistered source token is refused before quoting or signing" do
      params = base_params(%{from_chain_id: @unknown_chain, settlement: "public"})

      assert {:error,
              %Failure{
                reason: :route_unsupported,
                detail: {:unknown_asset, %{side: :source, chain_id: @unknown_chain}}
              }} = ExecuteXochiIntent.run(params, %{wallet: SpyWallet, xochi_config: config()})

      refute_received :wallet_signed
    end

    # A registered non-USD stablecoin scales correctly, but no spend cap reads
    # an FX rate, so it is refused as a
    # source under a dollar policy, even when a price for it is at hand.
    test "a non-USD stablecoin source is refused before signing" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      eurc_base = "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42"
      params = base_params(%{from_token: eurc_base, settlement: "public"})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        price_fn: Static.price_fn(%{"EURC" => "1.08"})
      }

      assert {:error,
              %Failure{
                reason: :invalid_request,
                detail:
                  {:unpriced_asset,
                   %{side: :source, chain_id: 8453, peg: "EUR", reason: :fx_unsupported}}
              }} = ExecuteXochiIntent.run(params, ctx)

      refute_received :wallet_signed
      assert Ledger.get_history(ledger, "a1") == []
    end

    # No quote stub: the refusal must land before any network call.
    test "an unregistered destination is refused even with min_to_amount" do
      for extra <- [%{}, %{min_to_amount: "950000"}] do
        params =
          base_params(Map.merge(%{to_chain_id: @unknown_chain, settlement: "public"}, extra))

        assert {:error,
                %Failure{
                  reason: :route_unsupported,
                  detail: {:unknown_asset, %{side: :destination, chain_id: @unknown_chain}}
                }} = ExecuteXochiIntent.run(params, %{wallet: SpyWallet, xochi_config: config()})
      end

      refute_received :wallet_signed
    end
  end

  describe "ExecuteXochiIntent method guard" do
    defp stub_quote_method(payment_method) do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            {body, conn} = XochiIntentFixture.quote_body(conn)

            Req.Test.json(conn, %{
              "intent_id" => "int_1",
              "quote_id" => "q_1",
              "can_solve" => true,
              "to_amount" => "499000",
              "payment_method" => payment_method,
              "eip712" => XochiIntentFixture.eip712(body, "499000")
            })

          "/api/intent/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing",
              "stealthAddress" => "0xstealth"
            })
        end
      end)
    end

    defp method_ctx do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      }
    end

    test "rejects an ERC-3009 quote for a non-USDC token before signing" do
      stub_quote_method("erc3009")
      # WETH on Base, not USDC.
      params =
        base_params(%{from_token: "0x4200000000000000000000000000000000000006"})

      assert {:error, %Failure{reason: :method_mismatch}} =
               ExecuteXochiIntent.run(params, method_ctx())

      refute_received :wallet_signed
    end

    test "allows an ERC-3009 quote for USDC" do
      stub_quote_method("erc3009")

      assert {:ok, result} =
               ExecuteXochiIntent.run(base_params(%{}), method_ctx())

      assert result.status == "executing"
      assert_received :wallet_signed
    end
  end
end

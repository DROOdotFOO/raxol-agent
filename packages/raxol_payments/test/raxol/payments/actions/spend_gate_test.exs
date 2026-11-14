defmodule Raxol.Payments.Actions.SpendGateTest do
  # Not async: the configured-source tests set `config :raxol_payments, :accounting`.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Ledger, SpendingPolicy}
  alias Raxol.Payments.Prices.Static

  @usdc {:token, 8453, "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"}
  @weth {:token, 8453, "0x4200000000000000000000000000000000000006"}
  @eurc {:token, 8453, "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42"}
  @usdt_tron {:token, 728_126_428, "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"}
  @unregistered {:token, 8453, "0x" <> String.duplicate("ab", 20)}

  defp start_ledger do
    ledger = start_supervised!({Ledger, [name: nil]})
    ledger
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("5.00"),
      lifetime_max: Decimal.new("10.00"),
      session_window_ms: 3_600_000,
      approved_domains: ["xochi.example.com"]
    }
  end

  defp usd_policy do
    %{policy() | per_request_max: Decimal.new("10"), session_max: Decimal.new("50")}
  end

  defp context(extra) do
    Map.merge(%{agent_id: "agent_1"}, extra)
  end

  defp lifetime(ledger, pol), do: Ledger.get_totals(ledger, "agent_1", pol).lifetime

  defp authorize(ctx, amount, asset) do
    SpendGate.authorize(ctx, Decimal.new(amount),
      asset: asset,
      target: {:domain, "xochi.example.com"}
    )
  end

  describe "authorize/3 with no policy" do
    test "allows when policy is absent and returns the amount unchanged" do
      assert {:ok, amount} = SpendGate.authorize(context(%{}), Decimal.new("9999"), asset: @weth)
      assert Decimal.equal?(amount, Decimal.new("9999"))
    end

    test "still refuses a spend that names no asset" do
      assert {:error, {:unpriced_asset, %{reason: :invalid_asset}}} =
               SpendGate.authorize(context(%{}), Decimal.new("1"))
    end

    test "still refuses a non-USD stablecoin" do
      assert {:error, {:unpriced_asset, %{reason: :fx_unsupported, peg: "EUR"}}} =
               SpendGate.authorize(context(%{}), Decimal.new("1"), asset: @eurc)
    end
  end

  describe "authorize/3 domain target" do
    test "approves and records when domain approved and under limits" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:ok, _} =
               SpendGate.authorize(ctx, Decimal.new("0.50"),
                 asset: @usdc,
                 target: {:domain, "xochi.example.com"}
               )

      assert Decimal.equal?(lifetime(ledger, policy()), Decimal.new("0.50"))
    end

    test "denies and does NOT record when domain not approved" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:deny, {:domain_not_approved, "evil.example.com"}}} =
               SpendGate.authorize(ctx, Decimal.new("0.10"),
                 asset: @usdc,
                 target: {:domain, "evil.example.com"}
               )

      assert Decimal.equal?(lifetime(ledger, policy()), Decimal.new("0"))
    end

    test "denies over per_request and does NOT record" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:over_budget, :per_request}} =
               SpendGate.authorize(ctx, Decimal.new("2.00"),
                 asset: @usdc,
                 target: {:domain, "xochi.example.com"}
               )

      assert Decimal.equal?(lifetime(ledger, policy()), Decimal.new("0"))
    end
  end

  describe "authorize/3 address target" do
    test "skips domain approval but applies confirmation threshold" do
      ledger = start_ledger()

      pol = %{policy() | require_confirmation_above: Decimal.new("0.10")}

      ctx = context(%{policy: pol, ledger: ledger})

      # over threshold, no on_confirm -> denied
      assert {:error, {:requires_confirmation, _}} =
               SpendGate.authorize(ctx, Decimal.new("0.50"),
                 asset: @usdc,
                 target: {:address, "0xabc"}
               )

      # under threshold -> allowed even with no approved domain match
      assert {:ok, _} =
               SpendGate.authorize(ctx, Decimal.new("0.05"),
                 asset: @usdc,
                 target: {:address, "0xabc"}
               )
    end

    test "address target with on_confirm approve proceeds" do
      ledger = start_ledger()
      pol = %{policy() | require_confirmation_above: Decimal.new("0.10")}

      ctx =
        context(%{
          policy: pol,
          ledger: ledger,
          on_confirm: fn _amount, _target -> :approve end
        })

      assert {:ok, _} =
               SpendGate.authorize(ctx, Decimal.new("0.50"),
                 asset: @usdc,
                 target: {:address, "0xabc"}
               )
    end
  end

  describe "authorize/3 amount validation" do
    test "rejects a negative amount and records nothing" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:invalid_amount, _}} = authorize(ctx, "-1.00", @usdc)
      assert Decimal.equal?(lifetime(ledger, policy()), Decimal.new("0"))
    end

    test "rejects a zero amount" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:invalid_amount, _}} = authorize(ctx, "0", @usdc)
    end

    test "rejects non-finite amounts without raising" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:error, {:invalid_amount, _}} = authorize(ctx, "Infinity", @usdc)
      assert {:error, {:invalid_amount, _}} = authorize(ctx, "NaN", @usdc)
    end

    test "a negative authorize cannot create phantom budget headroom" do
      ledger = start_ledger()
      # Session cap kept high so this exercises the lifetime cap specifically.
      pol = %{policy() | session_max: Decimal.new("100.00")}
      ctx = context(%{policy: pol, ledger: ledger})

      # Spend up to the lifetime cap of 10.00 in per-request-sized chunks.
      for _ <- 1..10 do
        assert {:ok, _} = authorize(ctx, "1.00", @usdc)
      end

      # A negative amount must not net down the total to free up headroom.
      assert {:error, {:invalid_amount, _}} = authorize(ctx, "-5.00", @usdc)

      # The lifetime cap is still enforced: no further real spend gets through.
      assert {:error, {:over_budget, :lifetime}} = authorize(ctx, "1.00", @usdc)

      assert Decimal.equal?(lifetime(ledger, pol), Decimal.new("10.00"))
    end
  end

  describe "authorize/3 require_policy" do
    test "fails closed when a policy is required but absent" do
      # No :policy in context -> the gate would otherwise be a no-op (unlimited).
      ctx = context(%{require_policy: true})

      assert {:error, {:policy_required, :no_spending_policy}} =
               SpendGate.authorize(ctx, Decimal.new("0.10"),
                 asset: @usdc,
                 target: {:domain, "x.test"}
               )
    end

    test "proceeds when a policy is present even with require_policy" do
      ledger = start_ledger()
      ctx = context(%{require_policy: true, policy: policy(), ledger: ledger})

      assert {:ok, _} = authorize(ctx, "0.50", @usdc)
    end

    test "stays permissive without the flag (unchanged default)" do
      assert {:ok, _} = SpendGate.authorize(context(%{}), Decimal.new("9999"), asset: @usdc)
    end
  end

  # The per-request cap needs no history, so it holds without a ledger, as it
  # does in AutoPay. Only the cumulative caps need one.
  describe "authorize/3 without a ledger" do
    test "1000 USDC is refused against dev()'s per-request cap" do
      ctx = context(%{policy: SpendingPolicy.dev(), require_policy: true})

      assert {:error, {:over_budget, :per_request}} =
               SpendGate.authorize(ctx, Decimal.new("1000"), asset: @usdc)
    end

    test "50 WETH at $3,000 is refused against dev()'s per-request cap" do
      ctx =
        context(%{
          policy: SpendingPolicy.dev(),
          price_fn: Static.price_fn(%{"WETH" => "3000"})
        })

      assert {:error, {:over_budget, :per_request}} =
               SpendGate.authorize(ctx, Decimal.new("50"), asset: @weth)
    end

    test "a spend within the per-request cap is allowed and converted" do
      ctx = context(%{policy: SpendingPolicy.dev()})

      assert {:ok, amount} = SpendGate.authorize(ctx, Decimal.new("0.05"), asset: @usdc)
      assert Decimal.equal?(amount, Decimal.new("0.05"))
    end

    test "an empty SpendingPolicy is refused as a configuration error, before pricing" do
      ctx = context(%{policy: %SpendingPolicy{}, price_fn: fn _ -> raise "not called" end})

      assert {:error, {:invalid_policy, :per_request_max} = reason} =
               SpendGate.authorize(ctx, Decimal.new("1000000"), asset: @weth)

      assert %Raxol.Payments.Failure{reason: :config_error, retryable?: false} =
               Raxol.Payments.Failure.from(reason)
    end

    test "a policy that is not a SpendingPolicy is refused as a configuration error" do
      ctx = context(%{policy: %{per_request_max: Decimal.new("1")}})

      assert {:error, {:invalid_policy, :not_a_policy}} =
               SpendGate.authorize(ctx, Decimal.new("0.5"), asset: @usdc)
    end
  end

  describe "authorize/3 policy validation with a ledger" do
    test "a cumulative cap the ledger needs is a configuration error, not over budget" do
      ledger = start_ledger()
      pol = %{policy() | session_max: nil}
      ctx = context(%{policy: pol, ledger: ledger})

      assert {:error, {:invalid_policy, :session_max}} = authorize(ctx, "0.50", @usdc)
      assert Ledger.get_history(ledger, "agent_1") == []
    end

    test "a non-Decimal per-request cap is a configuration error" do
      ledger = start_ledger()
      ctx = context(%{policy: %{policy() | per_request_max: 10}, ledger: ledger})

      assert {:error, {:invalid_policy, :per_request_max}} = authorize(ctx, "0.50", @usdc)
    end

    test "a valid policy with a ledger is unchanged" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      assert {:ok, _} = authorize(ctx, "0.50", @usdc)
      assert {:error, {:over_budget, :per_request}} = authorize(ctx, "2.00", @usdc)
      assert Decimal.equal?(lifetime(ledger, policy()), Decimal.new("0.50"))
    end
  end

  describe "release/2" do
    test "release nets out a prior authorize on totals" do
      ledger = start_ledger()
      ctx = context(%{policy: policy(), ledger: ledger})

      {:ok, reserved} = authorize(ctx, "0.75", @usdc)
      :ok = SpendGate.release(ctx, reserved)

      assert Decimal.equal?(lifetime(ledger, policy()), Decimal.new("0"))
    end
  end

  # Every spend is converted into the policy's unit before it is gated or
  # reserved (`Raxol.Payments.SpendPricing`).
  describe "authorize/3 policy unit" do
    setup do
      saved = Application.get_env(:raxol_payments, :accounting)
      Application.delete_env(:raxol_payments, :accounting)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:raxol_payments, :accounting, saved),
          else: Application.delete_env(:raxol_payments, :accounting)
      end)
    end

    test "a dollar stablecoin counts at par, on EVM and on Tron, with no price source" do
      ledger = start_ledger()
      ctx = context(%{policy: usd_policy(), ledger: ledger})

      assert {:ok, usdc} = authorize(ctx, "2.50", @usdc)
      assert Decimal.equal?(usdc, Decimal.new("2.50"))

      assert {:ok, usdt} = authorize(ctx, "1.25", @usdt_tron)
      assert Decimal.equal?(usdt, Decimal.new("1.25"))

      assert {:ok, ticker} =
               SpendGate.authorize(ctx, Decimal.new("1"),
                 asset: {:symbol, "usdc"},
                 target: {:address, "0xabc"}
               )

      assert Decimal.equal?(ticker, Decimal.new("1"))
      assert Decimal.equal?(lifetime(ledger, usd_policy()), Decimal.new("4.75"))
    end

    test "5 WETH at $3,000 is refused against a $10 per-request cap and records nothing" do
      ledger = start_ledger()

      ctx =
        context(%{
          policy: usd_policy(),
          ledger: ledger,
          price_fn: Static.price_fn(%{"WETH" => "3000"})
        })

      assert {:error, {:over_budget, :per_request}} = authorize(ctx, "5", @weth)
      assert Decimal.equal?(lifetime(ledger, usd_policy()), Decimal.new("0"))
    end

    test "0.002 WETH at $3,000 is reserved and recorded as 6 USD, with the token amount kept" do
      ledger = start_ledger()

      ctx =
        context(%{
          policy: usd_policy(),
          ledger: ledger,
          price_fn: Static.price_fn(%{"WETH" => "3000"})
        })

      assert {:ok, reserved} = authorize(ctx, "0.002", @weth)
      assert Decimal.equal?(reserved, Decimal.new("6"))
      assert Decimal.equal?(lifetime(ledger, usd_policy()), Decimal.new("6"))

      assert [%{amount: amount, currency: "USDC", metadata: metadata}] =
               Ledger.get_history(ledger, "agent_1")

      assert Decimal.equal?(amount, Decimal.new("6"))
      assert metadata.source_asset == @weth
      assert Decimal.equal?(metadata.source_amount, Decimal.new("0.002"))
    end

    test "a caller's low-precision Decimal context cannot undercount a converted spend" do
      ledger = start_ledger()

      ctx =
        context(%{
          policy: usd_policy(),
          ledger: ledger,
          price_fn: Static.price_fn(%{"WETH" => "3"})
        })

      previous = Decimal.Context.get()
      Decimal.Context.set(%Decimal.Context{precision: 2, rounding: :floor})

      try do
        assert {:ok, reserved} = authorize(ctx, "1.99", @weth)
        assert Decimal.equal?(reserved, Decimal.new("5.97"))
      after
        Decimal.Context.set(previous)
      end
    end

    test "the confirmation threshold sees the converted amount" do
      pol = %{usd_policy() | require_confirmation_above: Decimal.new("5")}
      ctx = context(%{policy: pol, price_fn: Static.price_fn(%{"WETH" => "3000"})})

      assert {:error, {:requires_confirmation, amount}} =
               SpendGate.authorize(ctx, Decimal.new("0.002"),
                 asset: @weth,
                 target: {:address, "0xabc"}
               )

      assert Decimal.equal?(amount, Decimal.new("6"))
    end

    test "a token with no price source configured is refused" do
      ctx = context(%{policy: usd_policy(), ledger: start_ledger()})

      assert {:error, {:unpriced_asset, %{reason: :no_price_source, unit: "USD"}}} =
               authorize(ctx, "0.002", @weth)
    end

    test "price_source: :none in the accounting config prices nothing" do
      Application.put_env(:raxol_payments, :accounting, price_source: :none, fx: nil)
      ctx = context(%{policy: usd_policy()})

      assert {:error, {:unpriced_asset, %{reason: :no_price_source}}} =
               authorize(ctx, "0.002", @weth)

      assert {:error, {:unpriced_asset, %{reason: :fx_unsupported}}} =
               authorize(ctx, "1", @eurc)
    end

    test "an unpriced token is refused: no symbol, or no price for it" do
      ctx =
        context(%{
          policy: usd_policy(),
          price_fn: Static.price_fn(%{"WETH" => "3000"})
        })

      assert {:error, {:unpriced_asset, %{reason: :no_price, token: _}}} =
               authorize(ctx, "1", @unregistered)

      assert {:error, {:unpriced_asset, %{reason: :no_price}}} =
               SpendGate.authorize(ctx, Decimal.new("1"),
                 asset: {:symbol, "RAXOL"},
                 target: {:address, "0xabc"}
               )
    end

    test "a stale price is refused" do
      an_hour_ago = System.system_time(:second) - 3600

      ctx =
        context(%{
          policy: usd_policy(),
          price_fn: Static.price_fn(%{"WETH" => "3000"}, as_of: an_hour_ago)
        })

      assert {:error, {:unpriced_asset, %{reason: :no_price}}} = authorize(ctx, "0.002", @weth)
    end

    test "a zero, negative, NaN or non-Decimal price is refused" do
      for price <- [Decimal.new("0"), Decimal.new("-3000"), Decimal.new("NaN"), 3000] do
        ctx = context(%{policy: usd_policy(), price_fn: fn "WETH" -> price end})

        assert {:error, {:unpriced_asset, %{reason: :invalid_price}}} =
                 authorize(ctx, "0.002", @weth)
      end
    end

    test "a price source that raises, exits or throws is refused" do
      for price_fn <- [
            fn _ -> raise "upstream down" end,
            fn _ -> exit(:timeout) end,
            fn _ -> throw(:unavailable) end
          ] do
        ctx = context(%{policy: usd_policy(), price_fn: price_fn})

        assert {:error, {:unpriced_asset, %{reason: :price_source_error}}} =
                 authorize(ctx, "0.002", @weth)
      end
    end

    test "EURC, EURe and ZCHF are refused under a USD policy, even with a price for them" do
      ctx =
        context(%{
          policy: usd_policy(),
          ledger: start_ledger(),
          price_fn: Static.price_fn(%{"EURC" => "1.08", "EURE" => "1.08", "ZCHF" => "1.1"})
        })

      assert {:error, {:unpriced_asset, %{reason: :fx_unsupported, peg: "EUR", unit: "USD"}}} =
               authorize(ctx, "5", @eurc)

      for ticker <- ["EURe", "ZCHF"] do
        assert {:error, {:unpriced_asset, %{reason: :fx_unsupported}}} =
                 SpendGate.authorize(ctx, Decimal.new("5"),
                   asset: {:symbol, ticker},
                   target: {:address, "0xabc"}
                 )
      end

      assert Ledger.get_history(ctx.ledger, "agent_1") == []
    end

    test "a EUR policy counts EURC at par and refuses USDC and WETH" do
      eur = %{usd_policy() | currency: "EUR"}

      ctx =
        context(%{
          policy: eur,
          price_fn: Static.price_fn(%{"WETH" => "3000", "USDC" => "1"})
        })

      assert {:ok, reserved} = authorize(ctx, "5", @eurc)
      assert Decimal.equal?(reserved, Decimal.new("5"))

      assert {:error, {:unpriced_asset, %{reason: :fx_unsupported, peg: "USD", unit: "EUR"}}} =
               authorize(ctx, "1", @usdc)

      assert {:error, {:unpriced_asset, %{reason: :policy_currency}}} =
               authorize(ctx, "0.002", @weth)
    end

    test "a policy whose currency is not a string refuses every spend" do
      ctx = context(%{policy: %{usd_policy() | currency: :usd}})

      assert {:error, {:unpriced_asset, %{reason: :policy_currency, unit: nil}}} =
               authorize(ctx, "1", @usdc)
    end
  end
end

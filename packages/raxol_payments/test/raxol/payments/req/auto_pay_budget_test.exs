defmodule Raxol.Payments.Req.AutoPayBudgetTest do
  # AutoPay after the policy gate: paid-retry redirects, the per-request cap,
  # the reservation around a signed payment, one budget unit across
  # protocols, and an unusable policy. Fixtures in Raxol.Payments.Test.AutoPayCase.
  use Raxol.Payments.Test.AutoPayCase, async: false

  alias Raxol.Payments.{Ledger, Req.AutoPay, SpendingPolicy}

  describe "paid retry redirects" do
    defp redirecting_stub(test_pid, location) do
      fn req ->
        paid? = Req.Request.get_header(req, "x-payment") != []
        send(test_pid, {:request, req.url.host, req.url.path, paid?})

        resp =
          cond do
            req.url.path == "/landed" ->
              Req.Response.new(status: 200, body: "ok")

            not paid? ->
              Req.Response.new(status: 402, body: "")
              |> Req.Response.put_header("payment-required", x402_challenge(1))

            true ->
              Req.Response.new(status: 307, body: "")
              |> Req.Response.put_header("location", location)
          end

        {req, resp}
      end
    end

    defp run_paid(location) do
      Req.new(url: "https://api.example.com/data", retry: false)
      |> AutoPay.attach(wallet: StubWallet, policy: SpendingPolicy.dev(), agent_id: :test)
      |> Req.Request.prepend_request_steps(stub: redirecting_stub(self(), location))
      |> Req.Request.run!()
    end

    test "a cross-origin redirect is followed without the payment" do
      assert %Req.Response{status: 200} = run_paid("https://cdn.example/landed")
      assert_received {:request, "api.example.com", "/data", true}
      assert_received {:request, "cdn.example", "/landed", false}
    end

    test "a same-origin redirect keeps the payment" do
      assert %Req.Response{status: 200} = run_paid("/landed")
      assert_received {:request, "api.example.com", "/data", true}
      assert_received {:request, "api.example.com", "/landed", true}
    end
  end

  describe "per-request cap" do
    setup do
      Process.put(:wallet_signal_target, self())
      :ok
    end

    test "without a ledger, an amount over per_request_max is refused before signing" do
      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        # dev(): per_request_max 0.10 USDC; 100_000_000 atomic is 100 USDC.
        |> AutoPay.attach(wallet: StubWallet, policy: SpendingPolicy.dev())
        |> Req.Request.prepend_request_steps(stub: stub_402_then_ok(100_000_000))

      resp = Req.Request.run!(req)

      assert resp.status == 402
      assert resp.body == %{error: :budget_exceeded, limit: :per_request}
      refute_received :wallet_signed
    end

    test "without a ledger, an amount within per_request_max is paid" do
      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        |> AutoPay.attach(wallet: StubWallet, policy: SpendingPolicy.dev())
        |> Req.Request.prepend_request_steps(stub: stub_402_then_ok(1))

      resp = Req.Request.run!(req)

      assert resp.status == 200
      assert_received :wallet_signed
    end

    test "with a ledger, the same over-cap amount is refused with the same body" do
      {:ok, ledger} =
        Ledger.start_link(table_name: :"cap_ledger_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end)

      req =
        Req.new(url: "https://api.example.com/data", retry: false)
        |> AutoPay.attach(
          wallet: StubWallet,
          ledger: ledger,
          policy: SpendingPolicy.dev(),
          agent_id: :cap
        )
        |> Req.Request.prepend_request_steps(stub: stub_402_then_ok(100_000_000))

      resp = Req.Request.run!(req)

      assert resp.status == 402
      assert resp.body == %{error: :budget_exceeded, limit: :per_request}
      refute_received :wallet_signed
      assert Ledger.get_history(ledger, :cap) == []
    end
  end

  describe "the reservation once a payment is signed, and when it is not" do
    setup do
      Process.put(:wallet_signal_target, self())

      {:ok, ledger} =
        Ledger.start_link(table_name: :"autopay_release_#{:erlang.unique_integer()}")

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1000"),
        session_max: Decimal.new("1000"),
        lifetime_max: Decimal.new("1000"),
        approved_domains: ["api.example.com"]
      }

      %{ledger: ledger, policy: policy}
    end

    test "a paid retry answered 500 keeps the spend recorded", %{ledger: ledger, policy: policy} do
      # 1_000_000 atomic = 1 USDC. The signed authorization has left the process
      # and the server can settle it, so the spend stays.
      resp = autopay_req(ledger, policy, stub_402_then_error(1_000_000)) |> Req.Request.run!()
      assert resp.status == 500
      assert_received :wallet_signed

      :timer.sleep(20)
      assert Decimal.equal?(lifetime(ledger, policy), "1")
    end

    test "a transport error on the paid retry keeps the spend recorded", %{
      ledger: ledger,
      policy: policy
    } do
      # First request 402s; the retry (carrying x-payment) fails in transport,
      # possibly after the server received the signed payment.
      stub = fn req ->
        if Req.Request.get_header(req, "x-payment") == [] do
          resp =
            Req.Response.new(status: 402, body: "")
            |> Req.Response.put_header("payment-required", x402_challenge(1_000_000))

          {req, resp}
        else
          {req, %Req.TransportError{reason: :econnrefused}}
        end
      end

      _resp = autopay_req(ledger, policy, stub) |> Req.Request.run!()

      :timer.sleep(20)
      assert Decimal.equal?(lifetime(ledger, policy), "1")
    end

    test "a server answering every paid retry with 500 is stopped at session_max", %{
      ledger: ledger
    } do
      # dev(): per_request_max 0.10, session_max 1.00. Each 402 asks 0.10.
      policy = SpendingPolicy.dev()

      statuses =
        for _ <- 1..15 do
          resp = autopay_req(ledger, policy, stub_402_then_error(100_000)) |> Req.Request.run!()
          {resp.status, resp.body}
        end

      signed = Enum.count(statuses, &match?({500, _}, &1))
      refused = Enum.count(statuses, &match?({402, %{error: :budget_exceeded}}, &1))

      assert signed == 10
      assert refused == 5
      :timer.sleep(20)
      assert Decimal.equal?(lifetime(ledger, policy), "1.0")
    end

    test "a signing failure releases the reservation", %{ledger: ledger, policy: policy} do
      resp =
        autopay_req(ledger, policy, stub_402_then_ok(1_000_000), FailingWallet)
        |> Req.Request.run!()

      assert resp.status == 402
      assert %{error: :payment_failed} = resp.body
      :timer.sleep(20)
      assert Decimal.equal?(lifetime(ledger, policy), "0")
    end

    test "an exception before anything is signed releases the reservation", %{
      ledger: ledger,
      policy: policy
    } do
      resp =
        autopay_req(ledger, policy, stub_402_then_ok(1_000_000), RaisingWallet)
        |> Req.Request.run!()

      assert resp.status == 402
      assert %{error: :payment_failed} = resp.body
      :timer.sleep(20)
      assert Decimal.equal?(lifetime(ledger, policy), "0")
    end

    test "an exit or throw before anything is signed releases the reservation", %{
      ledger: ledger,
      policy: policy
    } do
      for wallet <- [ExitingWallet, ThrowingWallet] do
        resp =
          autopay_req(ledger, policy, stub_402_then_ok(1_000_000), wallet)
          |> Req.Request.run!()

        assert resp.status == 402
        assert %{error: :payment_failed} = resp.body
        assert Decimal.equal?(lifetime(ledger, policy), "0")
      end
    end

    test "a malformed (float) price is rejected before any reservation or signing", %{
      ledger: ledger,
      policy: policy
    } do
      # A float price is not valid atomic units, so the x402 challenge is rejected
      # at parse: no protocol matches, nothing is reserved, nothing is signed.
      resp = autopay_req(ledger, policy, stub_402_then_ok(0.05)) |> Req.Request.run!()

      assert resp.status == 402
      refute_received :wallet_signed
      :timer.sleep(20)
      assert Decimal.equal?(Ledger.get_totals(ledger, :test, policy).lifetime, "0")
    end

    test "an all-digit price past 34 digits is refused by the budget, not raised", %{
      ledger: ledger,
      policy: policy
    } do
      # Valid atomic units by the parse rule (all digits), but wider than a
      # decimal128 string parse accepts. The server controls this value, so it
      # must reach the budget gate and be refused there, never crash the step.
      price = "1" <> String.duplicate("0", 40)
      resp = autopay_req(ledger, policy, stub_402_then_ok(price)) |> Req.Request.run!()

      assert resp.status == 402
      assert %{error: :budget_exceeded} = resp.body
      refute_received :wallet_signed
    end
  end

  describe "one unit across protocols" do
    setup do
      Process.put(:wallet_signal_target, self())

      {:ok, ledger} =
        Ledger.start_link(table_name: :"autopay_unit_#{:erlang.unique_integer()}")

      %{ledger: ledger}
    end

    test "an MPP charge of 5 USDC atomic is $0.000005 under dev(), and paid", %{ledger: ledger} do
      policy = SpendingPolicy.dev()

      resp =
        autopay_req(ledger, policy, stub_mpp_402_then_ok(%{"amount" => "5"}))
        |> Req.Request.run!()

      assert resp.status == 200
      assert Decimal.equal?(lifetime(ledger, policy), "0.000005")
    end

    test "an MPP charge of 50 US cents is $0.50, over dev()'s $0.10 per request", %{
      ledger: ledger
    } do
      policy = SpendingPolicy.dev()

      resp =
        autopay_req(
          ledger,
          policy,
          stub_mpp_402_then_ok(%{"amount" => "50", "currency" => "usd"})
        )
        |> Req.Request.run!()

      assert resp.status == 402
      assert %{error: :budget_exceeded, limit: :per_request} = resp.body
      assert Decimal.equal?(lifetime(ledger, policy), "0")
    end

    test "an x402 charge of 50 USDC passes a 50 per-request cap", %{ledger: ledger} do
      cap = Decimal.new("50")

      policy = %SpendingPolicy{
        per_request_max: cap,
        session_max: cap,
        lifetime_max: cap,
        approved_domains: ["api.example.com"]
      }

      resp = autopay_req(ledger, policy, stub_402_then_ok(50_000_000)) |> Req.Request.run!()

      assert resp.status == 200
      assert_received :wallet_signed
      assert Decimal.equal?(lifetime(ledger, policy), "50")
    end

    test "x402 WETH is not priced at par: refused, nothing reserved or signed", %{
      ledger: ledger
    } do
      policy = SpendingPolicy.unrestricted()

      challenge =
        %{
          "maxAmountRequired" => "1000000000000000000",
          "payTo" => "0x" <> String.duplicate("cd", 20),
          "asset" => "0x4200000000000000000000000000000000000006",
          "network" => "eip155:8453"
        }
        |> Jason.encode!()
        |> Base.encode64()

      stub = fn req ->
        {req,
         Req.Response.new(status: 402, body: "")
         |> Req.Response.put_header("payment-required", challenge)}
      end

      {resp, log} =
        ExUnit.CaptureLog.with_log(fn ->
          autopay_req(ledger, policy, stub) |> Req.Request.run!()
        end)

      assert resp.status == 402
      refute_received :wallet_signed
      assert Decimal.equal?(lifetime(ledger, policy), "0")
      # The refusal is logged by its tag only; the served challenge is not.
      assert log =~ "AutoPay passed a x402 402 through unpaid: :unsupported_asset"
      refute log =~ "0x4200000000000000000000000000000000000006"
    end

    test "MPP and x402 payments add up against one session cap", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1"),
        session_max: Decimal.new("1"),
        lifetime_max: Decimal.new("10")
      }

      # $0.60 by x402 USDC, then $0.30 by MPP in cents: $0.90 in session.
      assert %{status: 200} =
               autopay_req(ledger, policy, stub_402_then_ok(600_000)) |> Req.Request.run!()

      assert %{status: 200} =
               autopay_req(
                 ledger,
                 policy,
                 stub_mpp_402_then_ok(%{"amount" => 30, "currency" => "USD"})
               )
               |> Req.Request.run!()

      # A further $0.20 by MPP in USDC atomic units would make $1.10.
      resp =
        autopay_req(ledger, policy, stub_mpp_402_then_ok(%{"amount" => "200000"}))
        |> Req.Request.run!()

      assert resp.status == 402
      assert %{error: :budget_exceeded, limit: :session} = resp.body
      assert Decimal.equal?(lifetime(ledger, policy), "0.90")
    end

    test "a challenge in another currency than the policy's is refused", %{ledger: ledger} do
      policy = SpendingPolicy.unrestricted()

      resp =
        autopay_req(
          ledger,
          policy,
          stub_mpp_402_then_ok(%{"amount" => "100", "currency" => "EUR"})
        )
        |> Req.Request.run!()

      assert resp.status == 402
      assert %{error: :currency_mismatch, currency: "EUR", policy_currency: "USD"} = resp.body
      assert Decimal.equal?(lifetime(ledger, policy), "0")
    end

    test "a EUR policy pays a EUR challenge and refuses a USDC one", %{ledger: ledger} do
      policy = %{SpendingPolicy.unrestricted() | currency: "EUR"}

      assert %{status: 200} =
               autopay_req(
                 ledger,
                 policy,
                 stub_mpp_402_then_ok(%{"amount" => "250", "currency" => "eur"})
               )
               |> Req.Request.run!()

      resp = autopay_req(ledger, policy, stub_402_then_ok(1_000_000)) |> Req.Request.run!()
      assert %{error: :currency_mismatch, currency: "USD", policy_currency: "EUR"} = resp.body
      refute_received :wallet_signed
      assert Decimal.equal?(lifetime(ledger, policy), "2.50")
    end
  end

  describe "an unusable policy" do
    test "attach/2 raises when per_request_max is not a finite positive Decimal" do
      for cap <- [nil, Decimal.new(0), Decimal.new("-1"), Decimal.new("Infinity"), "1.00"] do
        policy = %{SpendingPolicy.dev() | per_request_max: cap}

        assert_raise ArgumentError, ~r/per_request_max must be a finite positive Decimal/, fn ->
          AutoPay.attach(Req.new(), wallet: StubWallet, policy: policy)
        end
      end
    end

    test "attach/2 with a ledger raises when a cumulative cap is missing" do
      policy = %{SpendingPolicy.dev() | session_max: nil}

      assert_raise ArgumentError, ~r/session_max/, fn ->
        AutoPay.attach(Req.new(), wallet: StubWallet, policy: policy, ledger: self())
      end

      assert %Req.Request{} = AutoPay.attach(Req.new(), wallet: StubWallet, policy: policy)
    end

    test "the ledger refuses a non-struct or nil-cap policy and keeps serving" do
      {:ok, ledger} =
        Ledger.start_link(table_name: :"autopay_badpolicy_#{:erlang.unique_integer()}")

      amount = Decimal.new("1")

      for policy <- [%{per_request_max: amount}, nil, %{SpendingPolicy.dev() | lifetime_max: nil}] do
        assert {:over_limit, :invalid_policy} = Ledger.try_spend(ledger, :a, amount, policy)
        assert {:over_limit, :invalid_policy} = Ledger.check_budget(ledger, :a, amount, policy)
      end

      assert {:over_limit, :invalid_policy} =
               Ledger.check_request(amount, %{per_request_max: amount})

      assert Process.alive?(ledger)
      assert :ok = Ledger.try_spend(ledger, :a, Decimal.new("0.05"), SpendingPolicy.dev())
    end
  end
end

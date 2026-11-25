defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntentRecoveryTest do
  use Raxol.Payments.Test.ExecuteXochiIntentCase, async: true

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Failure
  alias Raxol.Payments.Ledger
  alias Raxol.Payments.Prices.Static

  describe "ExecuteXochiIntent quote-expired retry" do
    test "re-quotes and re-executes once when the first execute reports expiry" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            n = Process.get(:execute_calls, 0)
            Process.put(:execute_calls, n + 1)

            if n == 0 do
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                409,
                Jason.encode!(%{"error" => "quote_expired"})
              )
            else
              Req.Test.json(conn, %{
                "success" => true,
                "intentId" => "int_1",
                "status" => "executing",
                "stealthAddress" => "0xstealth"
              })
            end
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

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.status == "executing"
      assert Process.get(:execute_calls) == 2

      # The reservation is held once across the retry, not double-charged.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "releases the reservation when the retry also fails" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              409,
              Jason.encode!(%{"error" => "quote_expired"})
            )
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

      assert {:error, %Failure{}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "the re-quote is held to the floor before it is signed" do
      # The first quote clears the automatic same-asset floor; after a 409 the
      # endpoint's re-quote delivers 1 (served and signed alike).
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            n = Process.get(:quote_calls, 0)
            Process.put(:quote_calls, n + 1)

            # Both the served and the signed toAmount drop to 1 on the re-quote,
            # so the intent binding holds and the floor is what refuses it.
            serve_quote(conn, quote_id: "q_#{n}", to_amount: if(n == 0, do: "499000", else: "1"))

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(409, Jason.encode!(%{"error" => "quote_expired"}))
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

      assert {:error, %Failure{reason: :delivery_below_floor, detail: {_, %{lowest: 1}}}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      # Only the first quote was signed; the reservation is released.
      assert_received :wallet_signed
      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "a re-quote with a mismatched method is refused before it is signed" do
      # WETH on Base is not USDC: the first quote names no method, the re-quote
      # after a 409 asks for ERC-3009, which signs against the USDC contract.
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            n = Process.get(:quote_calls, 0)
            Process.put(:quote_calls, n + 1)

            serve_quote(conn,
              quote_id: "q_#{n}",
              extra: %{"paymentMethod" => if(n == 0, do: nil, else: "erc3009")}
            )

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(409, Jason.encode!(%{"error" => "quote_expired"}))
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1",
        # 0.50 WETH at $1.50 is $0.75, inside the $1.00 per-request cap.
        price_fn: Static.price_fn(%{"WETH" => "1.50"})
      }

      params = base_params(%{from_token: "0x4200000000000000000000000000000000000006"})

      assert {:error, %Failure{reason: :method_mismatch}} = ExecuteXochiIntent.run(params, ctx)

      # Only the first quote was signed.
      assert_received :wallet_signed
      refute_received :wallet_signed
      assert :error = Checkpoint.fetch(store, "pay-1")

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))

      assert [%{reason: :requote_refused}] =
               for(
                 %{metadata: %{type: :release} = meta} <- Ledger.get_history(ledger, "a1"),
                 do: meta
               )
    end
  end

  describe "ExecuteXochiIntent idempotent recovery" do
    test "a repeated call resumes the in-flight intent instead of signing again" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, first} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert first.intent_id == "int_1"
      assert_received :wallet_signed

      # The process "restarts" and runs the same payment again.
      assert {:ok, second} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert second.intent_id == "int_1"
      refute_received :wallet_signed

      # Signed once, charged once.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "resumes a dispatched checkpoint without signing or charging (the crash window)" do
      # No stub: a resume must not touch the network at all.
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      # The first run dispatched the intent and checkpointed it, then the process
      # was killed before it could confirm -- this is that surviving record.
      Checkpoint.put(store, "pay-1", %{
        intent_id: "int_1",
        quote_id: "q_1",
        status: :dispatched
      })

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.status == "dispatched"
      refute_received :wallet_signed

      # Resume skips the spend gate: budget was already reserved on the first run.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "without a checkpoint store a repeat call signs again (the failure prevented)" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert_received :wallet_signed
      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert_received :wallet_signed

      # No checkpoint, no memory of the first payment: signed twice, charged twice.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("1.00"))
    end

    test "require_checkpoint with no store fails closed before signing or charging" do
      # No stub: the guard must trip before any network or signature.
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        require_checkpoint: true
      }

      assert {:error, %Failure{reason: :checkpoint_required, retryable?: false}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      # A missing durable checkpoint must stop the payment before it signs or
      # reserves budget -- the whole point is to prevent a crash-retry double-pay.
      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "settling without a checkpoint emits unchecked_settlement telemetry" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      handler_id = "unchecked-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :payments, :xochi, :unchecked_settlement],
        fn _e, _m, meta, _ -> send(test_pid, {:unchecked, meta}) end,
        nil
      )

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      try do
        assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)

        # The unchecked settlement is observable, never silent.
        assert_received {:unchecked, %{wallet: "0x1111111111111111111111111111111111111111"}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "records the in-flight intent in the checkpoint after submitting" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert {:ok, record} = Checkpoint.fetch(store, "pay-1")
      assert record.intent_id == "int_1"
    end

    test "distinct payments derive distinct keys and each signs" do
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

      assert {:ok, _} =
               ExecuteXochiIntent.run(base_params(%{amount: "0.50"}), ctx)

      assert_received :wallet_signed

      assert {:ok, _} =
               ExecuteXochiIntent.run(base_params(%{amount: "0.40"}), ctx)

      assert_received :wallet_signed
    end

    test "resumes via a ContextStore-backed checkpoint (the deployed-agent store)" do
      # Same resume, but through the store a real agent uses: the in-flight intent
      # rides the agent's durable context, not a throwaway ETS table.
      Raxol.Agent.ContextStore.init()
      store_id = :xochi_intent_recovery_test
      on_exit(fn -> Raxol.Agent.ContextStore.delete(store_id) end)
      store = Checkpoint.ContextStore.new(store_id)

      Checkpoint.put(store, "pay-1", %{intent_id: "int_1", status: :dispatched})

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.status == "dispatched"
      refute_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "drops the checkpoint for a structurally valid clean rejection" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              422,
              Jason.encode!(%{"error" => "request_rejected"})
            )
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:error, %Failure{}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      assert :error = Checkpoint.fetch(store, "pay-1")

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    @tag timeout: 300_000
    test "a quote whose signing fails releases and drops the checkpoint" do
      huge = String.duplicate("9", 5_000_000)

      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intentId" => "int_1",
              "quoteId" => "q_1",
              "canSolve" => true,
              "toAmount" => "499000",
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
                "types" => %{"Intent" => [%{"name" => "amount", "type" => "uint256"}]},
                "message" => %{"amount" => huge}
              }
            })
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: EncodingWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:error, %Failure{}} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert :error = Checkpoint.fetch(store, "pay-1")

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "a lost checkpoint race releases the reservation once and sends nothing" do
      parent = self()

      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            send(parent, :executed)
            Req.Test.json(conn, %{"success" => true, "intentId" => "int_1"})
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: {LostRaceStore, nil},
        idempotency_key: "pay-1"
      }

      assert {:error, %Failure{reason: :rejected, detail: :checkpoint_race, retryable?: false}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      refute_received :executed

      amounts = ledger |> Ledger.get_history("a1") |> Enum.map(& &1.amount)
      assert [released, reserved] = Enum.sort_by(amounts, &Decimal.to_float/1)
      assert Decimal.equal?(reserved, Decimal.new("0.50"))
      assert Decimal.equal?(released, Decimal.new("-0.50"))

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
      assert Decimal.equal?(totals.session, Decimal.new("0"))
    end
  end
end

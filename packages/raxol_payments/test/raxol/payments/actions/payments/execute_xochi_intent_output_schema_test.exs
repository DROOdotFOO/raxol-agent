defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntentOutputSchemaTest do
  use Raxol.Payments.Test.ExecuteXochiIntentCase, async: true

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Failure
  alias Raxol.Payments.Ledger
  alias Raxol.Payments.Test.XochiIntentFixture
  alias Raxol.Payments.Xochi.ReadTokenStore
  alias Raxol.Payments.Xochi.SettlementState

  # `call/2` validates the output against the output schema; `run/2` does not.
  # A public settlement has no stealth address and an unsettled poll no tx
  # hash; neither nil may trip its optional output field.
  describe "output schema via call/2 (public and stealth settlements)" do
    defp call_ctx do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      }
    end

    defp stub_quote(execute_json) do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            Req.Test.json(conn, execute_json)
        end
      end)
    end

    test "a public cross-chain settlement passes output validation with a nil stealth address" do
      # No stealthAddress in the execute response -> exec.stealth_address is nil,
      # exactly the public path the live gate runs.
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing"
      })

      params =
        base_params(%{settlement: "public", recipient_meta_address: nil})

      assert {:ok, result} = ExecuteXochiIntent.call(params, call_ctx())
      assert result.intent_id == "int_1"
      assert result.status == "executing"
      assert is_nil(result.stealth_address)
      assert_received :wallet_signed
    end

    test "a stealth settlement passes output validation with a real stealth address" do
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing",
        "stealthAddress" => "0xstealth"
      })

      assert {:ok, result} =
               ExecuteXochiIntent.call(base_params(%{}), call_ctx())

      assert result.intent_id == "int_1"
      assert result.stealth_address == "0xstealth"
      assert_received :wallet_signed
    end

    test "a stealth settlement that returns no stealth address fails closed" do
      # The worker accepted a stealth request but returned no stealth address, so
      # the funds may not be private. Reporting {:ok} here would silently defeat
      # the privacy the caller asked for; the Action must surface an error.
      stub_quote(%{"success" => true, "intentId" => "int_1", "status" => "executing"})

      assert {:error, %Failure{reason: :stealth_address_missing, retryable?: false}} =
               ExecuteXochiIntent.call(base_params(%{}), call_ctx())
    end

    test "a shielded settlement succeeds without a stealth address (note-based)" do
      # Shielded (Aztec) settlements are note-based: they carry no stealth address
      # (note_commitment / nullifier_hash surface at terminal status), so the
      # stealth-address guard must not apply to them.
      stub_quote(%{"success" => true, "intentId" => "int_1", "status" => "executing"})

      params = base_params(%{settlement: "shielded", recipient_meta_address: nil})

      assert {:ok, result} = ExecuteXochiIntent.call(params, call_ctx())
      assert result.intent_id == "int_1"
      assert is_nil(result.stealth_address)
    end

    test "a clean execute reports reconciling: false" do
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing",
        "stealthAddress" => "0xstealth"
      })

      assert {:ok, result} = ExecuteXochiIntent.call(base_params(%{}), call_ctx())
      assert result.reconciling == false
    end

    test "the execute read token stays out of the Action result and replay summary" do
      token = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      store = Checkpoint.ETS.new()

      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing",
        "stealthAddress" => "0xstealth",
        "read_token" => token
      })

      ctx = Map.merge(call_ctx(), %{checkpoint: store, idempotency_key: "pay-token"})
      assert {:ok, result} = ExecuteXochiIntent.call(base_params(%{}), ctx)
      refute Map.has_key?(result, :read_token)
      refute inspect(result) =~ token

      assert ReadTokenStore.fetch(
               store,
               config().base_url,
               "agent:a1",
               "int_1",
               System.system_time(:second)
             ) == token

      assert {:ok, %{summary: summary}} = Checkpoint.fetch(store, "pay-token")

      refute Map.has_key?(summary, :read_token)
      refute inspect(summary) =~ token
    end

    test "a 502 carrying read_token is dispatched and in doubt, keeping its checkpoint and reservation" do
      token = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_status(502)
            |> Req.Test.json(%{
              "success" => false,
              "intent_id" => "int_1",
              "status" => "completed",
              "error" => "solver",
              "read_token" => token
            })
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
        idempotency_key: "pay-502"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.reconciling == true
      refute Map.has_key?(result, :read_token)
      assert {:ok, %{summary: summary}} = Checkpoint.fetch(store, "pay-502")
      refute Map.has_key?(summary, :read_token)

      assert ReadTokenStore.fetch(
               store,
               config().base_url,
               "agent:a1",
               "int_1",
               System.system_time(:second)
             ) == token

      assert [] = for(%{metadata: %{type: :release}} <- Ledger.get_history(ledger, "a1"), do: 1)
    end

    test "ambiguous post-submit outcomes retain checkpoint and budget" do
      for outcome <- [:timeout, :closed, :invalid_json, :invalid_body, :server_500] do
        stub(fn conn ->
          case conn.request_path do
            "/api/intent/quote" ->
              serve_quote(conn)

            "/api/intent/execute" ->
              XochiIntentFixture.serve_ambiguous_execute(conn, outcome)
          end
        end)

        {:ok, ledger} =
          Ledger.start_link(table_name: :"xochi_unknown_#{System.unique_integer([:positive])}")

        store = Checkpoint.ETS.new()
        key = "pay-#{outcome}"

        ctx = %{
          wallet: SpyWallet,
          xochi_config: Map.update!(config(), :req_options, &Keyword.put(&1, :retry, false)),
          ledger: ledger,
          policy: policy(),
          agent_id: "a1",
          checkpoint: store,
          idempotency_key: key
        }

        assert {:ok, %{intent_id: "int_1", reconciling: true}} =
                 ExecuteXochiIntent.run(base_params(%{}), ctx)

        assert {:ok, %{intent_id: "int_1", summary: %{reconciling: true}}} =
                 Checkpoint.fetch(store, key)

        assert [] =
                 for(%{metadata: %{type: :release}} <- Ledger.get_history(ledger, "a1"), do: 1)

        assert Decimal.equal?(Ledger.get_totals(ledger, "a1", policy()).lifetime, "0.50")
      end
    end

    test "connect refusal releases the checkpoint and spend reservation" do
      base_url = quote_then_refuse_connections()

      {:ok, ledger} =
        Ledger.start_link(table_name: :"xochi_refused_#{System.unique_integer([:positive])}")

      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: %{base_url: base_url, auth: :none, req_options: [retry: false]},
        ledger: ledger,
        policy: %{policy() | approved_domains: ["127.0.0.1"]},
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-refused"
      }

      assert {:error, %Failure{reason: :network}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      assert :error = Checkpoint.fetch(store, "pay-refused")
      assert Decimal.equal?(Ledger.get_totals(ledger, "a1", policy()).lifetime, "0")
    end

    test "invalid base URL fails before checkpoint or spend reservation" do
      {:ok, ledger} =
        Ledger.start_link(table_name: :"xochi_invalid_url_#{System.unique_integer([:positive])}")

      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: %{base_url: "ftp://xochi.invalid", auth: :none},
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-invalid-url"
      }

      assert {:error, %Failure{reason: :unknown}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      assert :error = Checkpoint.fetch(store, "pay-invalid-url")
      assert Decimal.equal?(Ledger.get_totals(ledger, "a1", policy()).lifetime, "0")
      refute_received :wallet_signed
    end

    test "concurrent same-payment executes have one checkpoint owner and one POST" do
      test_pid = self()

      plug = fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            send(test_pid, {:execute_started, self()})

            receive do
              :release_execute ->
                Req.Test.json(conn, %{
                  "success" => true,
                  "intentId" => "int_1",
                  "status" => "executing",
                  "stealthAddress" => "0xstealth"
                })
            end
        end
      end

      {:ok, ledger} =
        Ledger.start_link(table_name: :"xochi_concurrent_#{System.unique_integer([:positive])}")

      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: %{base_url: "https://xochi.test", req_options: [plug: plug]},
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-concurrent"
      }

      first = Task.async(fn -> ExecuteXochiIntent.run(base_params(%{}), ctx) end)
      assert_receive {:execute_started, execute_pid}

      assert {:ok, %{dispatch_key: "pay-concurrent"}} =
               SettlementState.owner(
                 store,
                 ctx.xochi_config.base_url,
                 "agent:a1",
                 "int_1",
                 System.system_time(:second)
               )

      second = Task.async(fn -> ExecuteXochiIntent.run(base_params(%{}), ctx) end)
      assert {:ok, %{intent_id: "int_1", status: "dispatched"}} = Task.await(second)
      refute_received {:execute_started, _other}

      send(execute_pid, :release_execute)
      assert {:ok, %{intent_id: "int_1"}} = Task.await(first)
      refute_received {:execute_started, _other}

      assert {:ok, %{intent_id: "int_1", summary: %{intent_id: "int_1"}}} =
               Checkpoint.fetch(store, "pay-concurrent")
    end

    test "a refused execute releases this writer's checkpoint and budget" do
      refusals = [
        {409, %{"success" => false, "error" => "Intent already being executed"}},
        {400, %{"success" => false, "error" => "Cannot execute intent in executing status"}},
        {400, %{"success" => false, "error" => "Cannot execute intent in completed status"}}
      ]

      for {{status, body}, n} <- Enum.with_index(refusals) do
        stub(fn conn ->
          case conn.request_path do
            "/api/intent/quote" -> serve_quote(conn)
            "/api/intent/execute" -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
          end
        end)

        {:ok, ledger} =
          Ledger.start_link(table_name: :"xochi_claimed_#{System.unique_integer([:positive])}")

        store = Checkpoint.ETS.new()
        key = "pay-claimed-#{n}"

        ctx = %{
          wallet: SpyWallet,
          xochi_config: config(),
          ledger: ledger,
          policy: policy(),
          agent_id: "a1",
          checkpoint: store,
          idempotency_key: key
        }

        assert {:error, %Failure{}} = ExecuteXochiIntent.run(base_params(%{}), ctx)
        assert :error = Checkpoint.fetch(store, key)

        assert [_release] =
                 for(
                   %{metadata: %{type: :release}} = entry <-
                     Ledger.get_history(ledger, "a1"),
                   do: entry
                 )

        assert Decimal.equal?(Ledger.get_totals(ledger, "a1", policy()).lifetime, "0")
      end
    end

    test "a refusal because the intent expired is clean: budget released, checkpoint dropped" do
      stub(fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            serve_quote(conn)

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "success" => false,
              "error" => "Cannot execute intent in expired status"
            })
        end
      end)

      {:ok, ledger} =
        Ledger.start_link(table_name: :"xochi_expired_#{System.unique_integer([:positive])}")

      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-expired"
      }

      assert {:error, %Failure{}} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert :error = Checkpoint.fetch(store, "pay-expired")
      assert Decimal.equal?(Ledger.get_totals(ledger, "a1", policy()).lifetime, "0")
    end

    test "an older worker's execute returns no model-visible read token" do
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing",
        "stealthAddress" => "0xstealth"
      })

      assert {:ok, result} = ExecuteXochiIntent.call(base_params(%{}), call_ctx())
      refute Map.has_key?(result, :read_token)
    end

    test "an in-doubt (reconciling) execute surfaces reconciling, not a clean success" do
      # The worker could not confirm the solver executed (a Riddler 5xx/timeout
      # wrapped as a 200) and kept the intent non-terminal: success=true,
      # status=executing, reconciling=true, no tx hash. raxol must surface the
      # in-doubt state, not report a settled payment.
      stub_quote(%{
        "success" => true,
        "intent_id" => "int_1",
        "status" => "executing",
        "reconciling" => true
      })

      params = base_params(%{settlement: "public", recipient_meta_address: nil})

      assert {:ok, result} = ExecuteXochiIntent.call(params, call_ctx())
      assert result.status == "executing"
      assert result.reconciling == true
    end

    test "an in-doubt stealth execute is not misreported as a missing stealth address" do
      # A reconciling stealth execute has no stealth address yet (it appears once
      # the intent resolves to completed via polling). That is the in-doubt state,
      # not a privacy downgrade, so the stealth-address guard must not fail closed
      # here -- the in-doubt is surfaced via `reconciling` instead.
      stub_quote(%{
        "success" => true,
        "intent_id" => "int_1",
        "status" => "executing",
        "reconciling" => true
      })

      assert {:ok, result} = ExecuteXochiIntent.call(base_params(%{}), call_ctx())
      assert result.reconciling == true
      assert is_nil(result.stealth_address)
    end

    test "an explicit nil slippage falls back to the 50 bps default, never null" do
      # A present nil must not defeat the documented default and reach the worker
      # as null (an unbounded-slippage downgrade).
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

      assert {:ok, _} =
               ExecuteXochiIntent.call(base_params(%{slippage_bps: nil}), call_ctx())

      assert_received {:quote_body, body}
      assert body["slippage_bps"] == 50
    end
  end
end

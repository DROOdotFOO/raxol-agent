defmodule Raxol.Payments.Actions.Payments.ExecuteRelayTransferGaslessTest do
  # Gasless (Permit2 pull) funding: the canonical-pull check, the signed
  # execute, and what an execute in doubt keeps or releases.
  # Writes the global solver-pin settings, which other modules read.
  use Raxol.Payments.Test.ExecuteRelayTransferCase, async: false

  alias Raxol.Payments.Actions.Payments.{ExecuteRelayTransfer, PollRelayStatus}
  alias Raxol.Payments.Relay.Broadcaster
  alias Raxol.Payments.{Checkpoint, Failure, Ledger}

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  # Anvil/foundry default account #0 -- known private key for deterministic tests.
  @env_wallet_var "RAXOL_RELAY_GASLESS_TEST_KEY"
  @env_wallet_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  defmodule EnvWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_RELAY_GASLESS_TEST_KEY"
  end

  # A third-party wallet that does not rescue: it raises, exits or throws as
  # `:wallet_failure` in the process dictionary says.
  defmodule CrashingWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453

    def sign_typed_data(_d, _t, _m) do
      case Process.get(:wallet_failure) do
        :raise -> raise "signer crashed"
        :exit -> exit(:signer_down)
        :throw -> throw(:signer_threw)
      end
    end

    def sign_message(_), do: {:error, :unsupported}
    def sign_hash(_), do: {:error, :unsupported}
  end

  @solver "0x000000000000000000000000000000000000dEaD"

  # The Permit2 PermitWitnessTransferFrom + OriginPullWitness pull for
  # base_params/1 (0.50 USDC on Base = 500000 atomic), spender pinned.
  defp canonical_gasless(overrides \\ %{}) do
    Map.merge(
      %{
        "domain" => %{
          "name" => "Permit2",
          "chainId" => 8453,
          "verifyingContract" => Raxol.Payments.Protocols.Permit2.verifying_contract()
        },
        "primaryType" => "PermitWitnessTransferFrom",
        "types" => %{
          "PermitWitnessTransferFrom" => [
            %{"name" => "permitted", "type" => "TokenPermissions"},
            %{"name" => "spender", "type" => "address"},
            %{"name" => "nonce", "type" => "uint256"},
            %{"name" => "deadline", "type" => "uint256"},
            %{"name" => "witness", "type" => "OriginPullWitness"}
          ],
          "TokenPermissions" => [
            %{"name" => "token", "type" => "address"},
            %{"name" => "amount", "type" => "uint256"}
          ],
          "OriginPullWitness" => [%{"name" => "orderId", "type" => "bytes32"}]
        },
        "message" => %{
          "permitted" => %{"token" => @usdc_base, "amount" => "500000"},
          "spender" => @solver,
          "nonce" => "1",
          "deadline" => Integer.to_string(System.system_time(:second) + 600),
          "witness" => %{"orderId" => "0x" <> String.duplicate("cd", 32)}
        }
      },
      overrides
    )
  end

  defp stub_gasless(gasless) do
    stub_gasless(gasless, &Req.Test.json(&1, %{"transfer_id" => "t_1", "status" => "pending"}))
  end

  # The execute stub reads (and reports) the signed body before `respond`
  # answers, so the signature has reached the endpoint whatever it returns.
  defp stub_gasless(gasless, respond) do
    parent = self()

    stub(fn conn ->
      case conn.request_path do
        "/relay/quote" ->
          Req.Test.json(conn, %{
            "transfer_id" => "t_1",
            "quote_id" => "q_1",
            "can_fill" => true,
            "to_amount" => "499000",
            "deposit_address" => "0xdeposit",
            "gasless" => gasless
          })

        "/relay/execute" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:execute_body, Jason.decode!(raw)})
          respond.(conn)
      end
    end)
  end

  defp respond_status(status, body) do
    fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end
  end

  defp stub_status(body), do: stub(&Req.Test.json(&1, body))

  describe "gasless funding (A)" do
    setup do
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [@solver])
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)
    end

    test "signs the canonical Permit2 pull and sends the signature on execute" do
      stub_gasless(canonical_gasless())

      assert {:ok, result} =
               ExecuteRelayTransfer.run(
                 base_params(%{}),
                 ctx(%{broadcaster: Broadcaster.InMemory})
               )

      assert result.funding == "gasless"
      assert result.deposit_tx_hash == nil
      # Gasless means no broadcast even though a broadcaster was available.
      assert Broadcaster.InMemory.sent() == []

      assert_received {:execute_body, body}
      assert String.starts_with?(body["signature"], "0x")
    end

    test "refuses a gasless block that is not the canonical Permit2 pull, before signing" do
      hostile = [
        # An arbitrary struct of the server's choosing.
        %{
          "domain" => %{"name" => "Permit2", "chainId" => 8453},
          "types" => %{"Permit" => [%{"name" => "amount", "type" => "uint256"}]},
          "message" => %{"amount" => 500_000}
        },
        # The canonical envelope with an extra signable field.
        update_in(canonical_gasless(), ["message"], &Map.put(&1, "value", "1")),
        # An unpinned spender.
        put_in(canonical_gasless(), ["message", "spender"], "0x" <> String.duplicate("ab", 20)),
        # More than the transfer.
        put_in(canonical_gasless(), ["message", "permitted", "amount"], "500001")
      ]

      context = ctx(%{})

      for gasless <- hostile do
        stub_gasless(gasless)

        assert {:error,
                %Failure{reason: :rejected, detail: {:authorization_mismatch, {:gasless, _}}}} =
                 ExecuteRelayTransfer.run(base_params(%{}), context)

        refute_received {:execute_body, _}
      end
    end

    test "a served Permit2 value the encoder cannot take is refused and released" do
      System.put_env(@env_wallet_var, @env_wallet_key)
      on_exit(fn -> System.delete_env(@env_wallet_var) end)
      context = ctx(%{wallet: EnvWallet})

      probes = [
        put_in(canonical_gasless(), ["message", "nonce"], 1.5),
        put_in(canonical_gasless(), ["message", "nonce"], true),
        put_in(canonical_gasless(), ["message", "nonce"], %{"value" => "1"}),
        put_in(canonical_gasless(), ["message", "witness", "orderId"], 5)
      ]

      for gasless <- probes do
        stub_gasless(gasless)

        assert {:error, %Failure{}} = ExecuteRelayTransfer.run(base_params(%{}), context)
        refute_received {:execute_body, _}

        totals = Ledger.get_totals(context.ledger, "a1", policy())
        assert Decimal.equal?(totals.session, Decimal.new("0"))
        assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
      end
    end

    test "a wallet that raises, exits or throws is refused and the reservation released" do
      context = ctx(%{wallet: CrashingWallet})

      for failure <- [:raise, :exit, :throw] do
        Process.put(:wallet_failure, failure)
        stub_gasless(canonical_gasless())

        assert {:error, %Failure{reason: :sign_failed}} =
                 ExecuteRelayTransfer.run(base_params(%{}), context)

        refute_received {:execute_body, _}

        totals = Ledger.get_totals(context.ledger, "a1", policy())
        assert Decimal.equal?(totals.session, Decimal.new("0"))
      end
    end
  end

  # Once the signed Permit2 pull has reached the execute endpoint, the solver
  # may pull with it whatever the response says.
  describe "gasless execute in doubt" do
    setup do
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [@solver])
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)
      store = Checkpoint.ETS.new()
      %{context: ctx(%{checkpoint: store, idempotency_key: "pay-1"}), store: store}
    end

    test "a timeout after the signature was sent keeps the spend and checkpoint; poll, not retry",
         %{context: context, store: store} do
      stub_gasless(canonical_gasless(), &Req.Test.transport_error(&1, :timeout))

      assert {:ok, result} = ExecuteRelayTransfer.run(base_params(%{}), context)

      assert %{transfer_id: "t_1", status: "unknown", reconciling: true, funding: "gasless"} =
               result

      assert_received {:execute_body, %{"signature" => "0x" <> _}}

      assert Decimal.equal?(lifetime(context), Decimal.new("0.50"))
      assert {:ok, %{transfer_id: "t_1"}} = Checkpoint.fetch(store, "pay-1")

      # A re-run returns the same transfer to poll; nothing is signed or sent again.
      assert {:ok, ^result} = ExecuteRelayTransfer.run(base_params(%{}), context)
      refute_received {:execute_body, _}
      assert Decimal.equal?(lifetime(context), Decimal.new("0.50"))
    end

    test "the kept reservation is tagged, so a refund seen by polling releases it",
         %{context: context} do
      stub_gasless(canonical_gasless(), &Req.Test.transport_error(&1, :timeout))

      assert {:ok, %{reconciling: true}} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert Decimal.equal?(lifetime(context), Decimal.new("0.50"))

      stub_status(%{"transfer_id" => "t_1", "status" => "refunded"})

      assert {:error, %Failure{reason: :refunded}} =
               PollRelayStatus.run(%{transfer_id: "t_1"}, context)

      assert Decimal.equal?(lifetime(context), Decimal.new("0"))
    end

    test "a completion seen by polling keeps the spend", %{context: context} do
      stub_gasless(canonical_gasless(), &Req.Test.transport_error(&1, :timeout))

      assert {:ok, %{reconciling: true}} = ExecuteRelayTransfer.run(base_params(%{}), context)

      stub_status(%{"transfer_id" => "t_1", "status" => "completed", "tx_hash" => "abc123"})

      assert {:ok, %{status: "completed", terminal: true}} =
               PollRelayStatus.run(%{transfer_id: "t_1"}, context)

      assert Decimal.equal?(lifetime(context), Decimal.new("0.50"))
      assert :noop = Raxol.Payments.Actions.SpendGate.release_by_intent(context, "t_1")
      assert Decimal.equal?(lifetime(context), Decimal.new("0.50"))
    end

    test "a 5xx after the signature was sent keeps the spend", %{context: context, store: store} do
      stub_gasless(canonical_gasless(), respond_status(502, %{"error" => "bad_gateway"}))

      assert {:ok, %{transfer_id: "t_1", status: "unknown", reconciling: true}} =
               ExecuteRelayTransfer.run(base_params(%{}), context)

      assert Decimal.equal?(lifetime(context), Decimal.new("0.50"))
      assert {:ok, _record} = Checkpoint.fetch(store, "pay-1")
    end

    test "a 4xx rejection releases the spend and drops the checkpoint",
         %{context: context, store: store} do
      stub_gasless(canonical_gasless(), respond_status(400, %{"error" => "validation_failed"}))

      assert {:error, %Failure{}} = ExecuteRelayTransfer.run(base_params(%{}), context)

      assert Decimal.equal?(lifetime(context), Decimal.new("0"))
      assert :error = Checkpoint.fetch(store, "pay-1")
    end

    test "a connection refused before anything was sent releases the spend",
         %{context: context, store: store} do
      stub_gasless(canonical_gasless(), &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Failure{}} = ExecuteRelayTransfer.run(base_params(%{}), context)

      assert Decimal.equal?(lifetime(context), Decimal.new("0"))
      assert :error = Checkpoint.fetch(store, "pay-1")
    end
  end
end

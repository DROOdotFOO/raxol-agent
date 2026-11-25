defmodule Raxol.Payments.Actions.Payments.ExecuteRelayTransferTest do
  # Writes the global solver-pin settings, which other modules read.
  use Raxol.Payments.Test.ExecuteRelayTransferCase, async: false

  alias Raxol.Payments.Actions.Payments.{ExecuteRelayTransfer, PollRelayStatus}
  alias Raxol.Payments.Relay.Broadcaster
  alias Raxol.Payments.{Checkpoint, Failure, Ledger}

  @tron 728_126_428
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  describe "happy path" do
    test "quotes, gates, executes, returns the deposit address and status" do
      stub_quote_and_execute()

      assert {:ok, result} = ExecuteRelayTransfer.run(base_params(%{}), ctx())
      assert result.transfer_id == "t_1"
      assert result.deposit_address == "0xdeposit"
      assert result.status == "pending"
      assert result.to_amount == "499000"
      assert result.warnings == []
      # No gasless quote and no broadcaster: the caller funds the deposit.
      assert result.funding == "external"
      assert result.deposit_tx_hash == nil
    end
  end

  describe "broadcast funding (B)" do
    test "broadcasts the deposit on an EVM source when a broadcaster is present" do
      stub_quote_and_execute()

      assert {:ok, result} =
               ExecuteRelayTransfer.run(
                 base_params(%{}),
                 ctx(%{broadcaster: Broadcaster.InMemory})
               )

      assert result.funding == "broadcast"
      assert result.deposit_tx_hash == "0xdeposit_t_1"

      assert [send] = Broadcaster.InMemory.sent()
      assert send.to == "0xdeposit"
      assert send.amount_atomic == "500000"
      assert send.chain_id == 8453
    end

    test "releases the reservation when the broadcaster proves nothing was sent" do
      stub_quote_and_execute()
      Process.put(:relay_broadcaster_fail, {:not_sent, :rpc_down})
      context = ctx(%{broadcaster: Broadcaster.InMemory})

      assert {:error, %Failure{}} = ExecuteRelayTransfer.run(base_params(%{}), context)

      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "keeps the reservation and checkpoint when the broadcast outcome is unknown" do
      stub_quote_and_execute()
      Process.put(:relay_broadcaster_fail, :receipt_timeout)
      store = Checkpoint.ETS.new()

      context =
        ctx(%{broadcaster: Broadcaster.InMemory, checkpoint: store, idempotency_key: "pay-1"})

      assert {:ok, result} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert result.transfer_id == "t_1"
      assert result.status == "unknown"
      assert result.reconciling == true
      assert result.funding == "broadcast"
      assert result.deposit_address == "0xdeposit"
      assert result.deposit_tx_hash == nil

      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
      assert {:ok, %{transfer_id: "t_1"}} = Checkpoint.fetch(store, "pay-1")
    end

    test "a broadcaster that raises leaves the outcome in doubt" do
      stub_quote_and_execute()
      context = ctx(%{broadcaster: RaisingBroadcaster})

      assert {:ok, %{transfer_id: "t_1", status: "unknown", reconciling: true}} =
               ExecuteRelayTransfer.run(base_params(%{}), context)

      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "an execute that times out before any broadcast or signature releases" do
      stub(fn conn ->
        case conn.request_path do
          "/relay/quote" ->
            Req.Test.json(conn, %{
              "transfer_id" => "t_1",
              "quote_id" => "q_1",
              "can_fill" => true,
              "to_amount" => "499000",
              "deposit_address" => "0xdeposit"
            })

          "/relay/execute" ->
            Req.Test.transport_error(conn, :timeout)
        end
      end)

      context = ctx(%{broadcaster: Broadcaster.InMemory})

      assert {:error, %Failure{}} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert Broadcaster.InMemory.sent() == []

      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "does not broadcast a Tron source leg (raxol cannot)" do
      stub(fn conn ->
        case conn.request_path do
          "/relay/quote" ->
            Req.Test.json(conn, %{
              "transfer_id" => "t_1",
              "quote_id" => "q_1",
              "can_fill" => true,
              "to_amount" => "499000",
              "deposit_address" => @tron_addr
            })

          "/relay/execute" ->
            Req.Test.json(conn, %{"transfer_id" => "t_1", "status" => "pending"})
        end
      end)

      params =
        base_params(%{
          from_chain_id: @tron,
          to_chain_id: 8453,
          from_token: @usdt_trc20,
          to_token: @usdc_base,
          to_address: "0x" <> String.duplicate("cd", 20),
          from_address: @tron_addr
        })

      assert {:ok, result} =
               ExecuteRelayTransfer.run(params, ctx(%{broadcaster: Broadcaster.InMemory}))

      assert result.funding == "external"
      assert Broadcaster.InMemory.sent() == []
    end
  end

  describe "stealth on Tron" do
    test "rejects a stealth request before any quote or spend, not silent downgrade" do
      parent = self()

      # Any relay call would notify `parent`; the rejection must beat it.
      stub(fn conn ->
        send(parent, {:relay_called, conn.request_path})
        Req.Test.json(conn, %{})
      end)

      assert {:error, %Failure{reason: :stealth_unsupported}} =
               ExecuteRelayTransfer.run(base_params(%{settlement: "stealth"}), ctx())

      refute_received {:relay_called, _}
    end

    test "rejects a shielded request to a Tron destination the same way" do
      assert {:error, %Failure{reason: :stealth_unsupported}} =
               ExecuteRelayTransfer.run(base_params(%{settlement: "shielded"}), ctx())
    end
  end

  describe "validation and routing" do
    test "rejects an EVM address on the Tron leg before any network call" do
      params = base_params(%{to_address: "0x" <> String.duplicate("ab", 20)})

      assert {:error, %Failure{reason: :invalid_request}} =
               ExecuteRelayTransfer.run(params, ctx())
    end

    test "rejects a route with no Tron leg" do
      params =
        base_params(%{to_chain_id: 42_161, to_address: "0x" <> String.duplicate("ab", 20)})

      assert {:error, %Failure{reason: :route_unsupported}} =
               ExecuteRelayTransfer.run(params, ctx())
    end

    test "refuses a non-USD stablecoin source before execute (ADR-0040)" do
      parent = self()

      stub(fn conn ->
        send(parent, {:relay_called, conn.request_path})

        Req.Test.json(conn, %{
          "transfer_id" => "t_1",
          "quote_id" => "q_1",
          "can_fill" => true,
          "to_amount" => "499000",
          "deposit_address" => "0xdeposit"
        })
      end)

      params = base_params(%{from_token: "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42"})

      assert {:error,
              %Failure{
                reason: :invalid_request,
                detail:
                  {:unpriced_asset,
                   %{side: :source, chain_id: 8453, peg: "EUR", reason: :fx_unsupported}}
              }} = ExecuteRelayTransfer.run(params, ctx())

      refute_received {:relay_called, "/relay/execute"}
    end
  end

  # `amount` is a human amount of `from_token`; the gate converts it into the
  # policy's unit before it reserves anything or the transfer is funded.
  describe "policy unit" do
    @weth_base "0x4200000000000000000000000000000000000006"

    defp weth_ctx(overrides \\ %{}) do
      ctx(
        Map.merge(
          %{
            policy: policy(%{per_request_max: Decimal.new("10"), session_max: Decimal.new("50")}),
            price_fn: Raxol.Payments.Prices.Static.price_fn(%{"WETH" => "3000"})
          },
          overrides
        )
      )
    end

    test "0.002 WETH at $3,000 is reserved as 6 USD and broadcast at 18 decimals" do
      stub_quote_and_execute()
      ctx = weth_ctx(%{broadcaster: Broadcaster.InMemory})

      assert {:ok, %{funding: "broadcast"}} =
               ExecuteRelayTransfer.run(
                 base_params(%{amount: "0.002", from_token: @weth_base}),
                 ctx
               )

      assert [%{amount: amount, metadata: %{protocol: :relay}}] =
               Ledger.get_history(ctx.ledger, "a1")

      assert Decimal.equal?(amount, Decimal.new("6"))
      assert [%{amount_atomic: "2000000000000000"}] = Broadcaster.InMemory.sent()
    end

    test "5 WETH at $3,000 is refused against a $10 per-request cap and nothing is funded" do
      stub_quote_and_execute()
      ctx = weth_ctx(%{broadcaster: Broadcaster.InMemory})

      assert {:error, %Failure{reason: :over_budget}} =
               ExecuteRelayTransfer.run(base_params(%{amount: "5", from_token: @weth_base}), ctx)

      assert Ledger.get_history(ctx.ledger, "a1") == []
      assert Broadcaster.InMemory.sent() == []
    end

    test "an unregistered source token is refused before quoting under a policy" do
      stub_quote_and_execute()
      params = base_params(%{from_token: "0x" <> String.duplicate("ab", 20)})

      assert {:error, %Failure{detail: {:unknown_asset, %{side: :source}}}} =
               ExecuteRelayTransfer.run(params, weth_ctx())
    end

    test "an unregistered source token is refused with no policy too" do
      stub_quote_and_execute()
      params = base_params(%{from_token: "0x" <> String.duplicate("ab", 20)})

      assert {:error, %Failure{detail: {:unknown_asset, %{side: :source}}}} =
               ExecuteRelayTransfer.run(params, ctx(%{policy: nil}))
    end
  end

  describe "spend gate" do
    test "denies over per_request and does not execute" do
      stub_quote_and_execute()

      assert {:error, %Failure{reason: :over_budget}} =
               ExecuteRelayTransfer.run(
                 base_params(%{}),
                 ctx(%{policy: policy(%{per_request_max: Decimal.new("0.10")})})
               )
    end
  end

  describe "idempotent recovery" do
    test "a repeated call resumes the in-flight transfer instead of re-broadcasting" do
      stub_quote_and_execute()
      store = Checkpoint.ETS.new()

      context =
        ctx(%{broadcaster: Broadcaster.InMemory, checkpoint: store, idempotency_key: "pay-1"})

      assert {:ok, first} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert first.transfer_id == "t_1"
      assert first.funding == "broadcast"
      assert [_one] = Broadcaster.InMemory.sent()

      # The process "restarts" and runs the same payment again.
      assert {:ok, second} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert second.transfer_id == "t_1"

      # Resumed from the checkpoint: no second deposit, charged once.
      assert [_still_one] = Broadcaster.InMemory.sent()
      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "resumes a dispatched checkpoint without re-funding (the crash window)" do
      store = Checkpoint.ETS.new()

      # An earlier run dispatched the transfer and checkpointed it, then died
      # before confirming -- this is that surviving record.
      Checkpoint.put(store, "pay-1", %{
        transfer_id: "t_1",
        quote_id: "q_1",
        deposit_address: "0xdeposit",
        status: :dispatched
      })

      context =
        ctx(%{broadcaster: Broadcaster.InMemory, checkpoint: store, idempotency_key: "pay-1"})

      assert {:ok, result} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert result.transfer_id == "t_1"
      assert result.deposit_address == "0xdeposit"
      assert result.status == "dispatched"

      # No network, no broadcast, no spend: the first run already reserved it.
      assert Broadcaster.InMemory.sent() == []
      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "without a checkpoint store a repeat re-runs the payment (the failure prevented)" do
      stub_quote_and_execute()
      context = ctx(%{broadcaster: Broadcaster.InMemory})

      assert {:ok, _} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert {:ok, _} = ExecuteRelayTransfer.run(base_params(%{}), context)

      # No checkpoint, no memory of the first transfer: re-quoted, re-authorized,
      # re-signed, charged twice. (The deposit dedupes only because this stub
      # echoes a constant transfer_id; a live run mints a fresh one and the
      # broadcast doubles too.)
      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("1.00"))
    end

    test "records the in-flight transfer in the checkpoint after funding" do
      stub_quote_and_execute()
      store = Checkpoint.ETS.new()
      context = ctx(%{checkpoint: store, idempotency_key: "pay-1"})

      assert {:ok, _} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert {:ok, record} = Checkpoint.fetch(store, "pay-1")
      assert record.transfer_id == "t_1"
    end

    test "drops the checkpoint when funding fails so a retry starts clean" do
      stub_quote_and_execute()
      Process.put(:relay_broadcaster_fail, {:not_sent, :rpc_down})
      store = Checkpoint.ETS.new()

      context =
        ctx(%{broadcaster: Broadcaster.InMemory, checkpoint: store, idempotency_key: "pay-1"})

      assert {:error, %Failure{}} = ExecuteRelayTransfer.run(base_params(%{}), context)
      assert :error = Checkpoint.fetch(store, "pay-1")

      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "delivery floor" do
    @eure_arb "0x0c06ccf38114ddfc35e07427b9424adcca9f44f8"

    defp stub_delivering(to_amount) do
      stub(fn conn ->
        case conn.request_path do
          "/relay/quote" ->
            Req.Test.json(conn, %{
              "transfer_id" => "t_1",
              "quote_id" => "q_1",
              "can_fill" => true,
              "to_amount" => to_amount,
              "deposit_address" => @tron_addr
            })

          "/relay/execute" ->
            send(self(), :relay_executed)
            Req.Test.json(conn, %{"transfer_id" => "t_1", "status" => "pending"})
        end
      end)
    end

    defp tron_to_eure(overrides) do
      base_params(
        Map.merge(
          %{
            from_chain_id: @tron,
            to_chain_id: 42_161,
            from_token: @usdt_trc20,
            to_token: @eure_arb,
            to_address: "0x" <> String.duplicate("cd", 20),
            from_address: @tron_addr
          },
          overrides
        )
      )
    end

    test "a non-USD destination without min_to_amount is refused before execute" do
      stub_delivering("1")
      context = ctx()

      assert {:error,
              %Failure{
                reason: :invalid_request,
                detail: {:unpriced_asset, %{side: :destination, chain_id: 42_161, peg: "EUR"}}
              }} = ExecuteRelayTransfer.run(tron_to_eure(%{}), context)

      refute_received :relay_executed
      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "a zero min_to_amount counts as absent, so the non-USD destination is still refused" do
      stub_delivering("1")

      assert {:error, %Failure{detail: {:unpriced_asset, %{side: :destination}}}} =
               ExecuteRelayTransfer.run(tron_to_eure(%{min_to_amount: "0"}), ctx())

      refute_received :relay_executed
    end

    test "a quote below an explicit min_to_amount is refused before the spend is authorized" do
      stub_delivering("490000000000000000")
      context = ctx()

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteRelayTransfer.run(
                 tron_to_eure(%{min_to_amount: "500000000000000000"}),
                 context
               )

      refute_received :relay_executed
      totals = Ledger.get_totals(context.ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "a quote meeting an explicit min_to_amount executes" do
      stub_delivering("500000000000000000")

      assert {:ok, %{status: "pending"}} =
               ExecuteRelayTransfer.run(
                 tron_to_eure(%{min_to_amount: "500000000000000000"}),
                 ctx()
               )

      assert_received :relay_executed
    end

    test "an explicit min_to_amount also binds a USD corridor" do
      stub_delivering("499000")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteRelayTransfer.run(base_params(%{min_to_amount: "499001"}), ctx())

      refute_received :relay_executed
    end

    test "a min_to_amount that is not an integer of atomic units is refused, not ignored" do
      stub_delivering("1")
      context = ctx()

      for floor <- ["1e6", "499000.0", "-1", "abc"] do
        assert {:error,
                %Failure{reason: :invalid_request, detail: {:invalid_min_to_amount, ^floor}}} =
                 ExecuteRelayTransfer.run(base_params(%{min_to_amount: floor}), context)
      end

      refute_received :relay_executed
    end

    test "a floor in the source's units on a non-USD destination is refused" do
      stub_delivering("1000000")

      assert {:error, %Failure{detail: {:implausible_min_to_amount, _}}} =
               ExecuteRelayTransfer.run(tron_to_eure(%{min_to_amount: "990000"}), ctx())

      refute_received :relay_executed
    end
  end

  describe "PollRelayStatus" do
    test "returns a completed transfer" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "transfer_id" => "t_1",
          "status" => "completed",
          "tx_hash" => "abc123"
        })
      end)

      assert {:ok, result} = PollRelayStatus.run(%{transfer_id: "t_1"}, %{relay_config: config()})
      assert result.status == "completed"
      assert result.terminal == true
      assert result.tx_hash == "abc123"
      assert result.settlement_speed == "within_budget"
    end

    test "surfaces a failed transfer as an error" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "transfer_id" => "t_2",
          "status" => "failed",
          "error" => "bridge unavailable"
        })
      end)

      assert {:error, %Failure{}} =
               PollRelayStatus.run(%{transfer_id: "t_2"}, %{relay_config: config()})
    end
  end
end

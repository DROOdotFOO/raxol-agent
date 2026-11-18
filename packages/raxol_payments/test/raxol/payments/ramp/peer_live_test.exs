defmodule Raxol.Payments.Ramp.PeerLiveTest do
  use ExUnit.Case, async: false
  alias Raxol.Payments.{ChainReader, Checkpoint, Ledger, SpendingPolicy}
  alias Raxol.Payments.ChainReader.JSONRPC
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer
  alias Raxol.Payments.Ramp.Peer.{ABI, Indexer, LiveIO, LiveReads, Mapping, Plans, Wallet}
  @now ~U[2026-11-16 12:00:00Z]
  @owner "0x0000000000000000000000000000000000000001"
  @zero "0x0000000000000000000000000000000000000000"

  defmodule CrashCheckpoint do
    @behaviour Checkpoint
    alias Checkpoint.ETS

    defdelegate fetch(table, key), to: ETS
    defdelegate delete(table, key), to: ETS
    defdelegate sweep_expired(table, now), to: ETS

    def put(table, key, record) do
      interrupt({:before_put, key, record})
      :ok = ETS.put(table, key, record)
      interrupt({:after_put, key, record})
    end

    def put_new(table, key, record) do
      with :ok <- ETS.put_new(table, key, record), do: interrupt({:after_insert, key, record})
    end

    defp interrupt(event) do
      if Process.get(__MODULE__, fn _ -> false end).(event), do: Process.exit(self(), :kill)
      :ok
    end
  end

  defmodule MemoryChain do
    @now ~U[2026-11-16 12:00:00Z]
    @behaviour ChainReader
    def get_receipt(_, _, _), do: {:error, :not_found}
    def get_balance(_, _, _), do: {:error, :not_found}
    def get_erc20_balance(_, _, _, _), do: {:error, :not_found}

    def broadcast(pid, 8453, _raw) do
      Agent.update(pid, &Map.update!(&1, :broadcasts, fn n -> n + 1 end))
      {:error, :lost_response}
    end

    def request(pid, 8453, method, params) do
      Agent.get_and_update(pid, fn s ->
        result = if s.fault == method, do: {:error, :unavailable}, else: reply(s, method, params)
        {result, Map.update!(s, :calls, fn n -> n + 1 end)}
      end)
    end

    defp reply(_, "eth_chainId", []), do: {:ok, "0x2105"}
    defp reply(_, "eth_blockNumber", []), do: {:ok, "0x66"}

    defp reply(_, "eth_getBlockByNumber", ["0x64", false]),
      do: {:ok, %{"number" => "0x64", "timestamp" => LiveReads.hex(DateTime.to_unix(@now))}}

    defp reply(_, "eth_getBlockByNumber", ["finalized", false]), do: {:ok, %{"number" => "0x64"}}
    defp reply(s, "eth_getTransactionCount", [_, "finalized"]), do: {:ok, s.finalized_nonce}
    defp reply(_, "eth_getTransactionCount", _), do: {:ok, "0x0"}
    defp reply(_, "eth_gasPrice", _), do: {:ok, "0x1"}
    defp reply(_, "eth_maxPriorityFeePerGas", _), do: {:ok, "0x1"}
    defp reply(_, "eth_estimateGas", _), do: {:ok, "0x186a0"}
    defp reply(s, "eth_getTransactionByHash", [hash]), do: Map.fetch(s.transactions, hash)
    defp reply(s, "eth_getTransactionReceipt", [hash]), do: Map.fetch(s.receipts, hash)
    defp reply(_, "eth_call", [_, "latest"]), do: {:ok, "0x"}
    defp reply(s, "eth_call", [%{to: to, data: data}, "0x64"]), do: Map.fetch(s.reads, {to, data})
  end

  defmodule ReviewWallet do
    @owner "0x0000000000000000000000000000000000000001"
    def address, do: @owner
    def chain_id, do: 8453

    def sign_hash(_digest) do
      send(self(), :sign_requested)
      {:error, :user_rejected}
    end
  end

  defmodule DeferredWallet do
    @behaviour Peer.MakerWallet
    def validate(context, plan, terms), do: Wallet.validate(context, plan, terms)

    def request(context, operation, pending, plan) do
      {:ok, mapping} = Mapping.fetch_maker(context, operation)
      :ok = Mapping.put_maker(context, operation, %{mapping | pending_kind: plan.action})
      send(self(), {:wallet_handoff, operation, pending, plan})
      :ok
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "peer-live-#{System.unique_integer([:positive])}")

    mapping =
      start_supervised!({Mapping, path: Path.join(tmp, "mapping.dets"), name: :peer_live_test})

    on_exit(fn -> File.rm_rf!(tmp) end)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             reads: %{},
             calls: 0,
             broadcasts: 0,
             fault: nil,
             finalized_nonce: "0x0",
             transactions: %{},
             receipts: %{},
             rate_limit: nil,
             index_calls: 0,
             index: index(),
             allowance: 3_000_000
           }
         end}
      )

    indexer =
      start_supervised!(
        {Indexer,
         now: fn -> DateTime.to_unix(@now, :millisecond) end,
         req_options: [
           plug: fn conn ->
             {:ok, body, conn} = Plug.Conn.read_body(conn)
             query = Jason.decode!(body)["query"]
             Agent.update(state, &Map.update!(&1, :index_calls, fn n -> n + 1 end))

             case Agent.get(state, & &1.rate_limit) do
               nil ->
                 data =
                   if String.contains?(query, "MakerTemplate"),
                     do: template(),
                     else: Agent.get(state, & &1.index)

                 Plug.Conn.send_resp(conn, 200, Jason.encode!(%{data: data}))

               after_value ->
                 conn
                 |> Plug.Conn.put_resp_header("retry-after", after_value)
                 |> Plug.Conn.send_resp(429, "")
             end
           end
         ]}
      )

    reader = {MemoryChain, state}

    crypto = %{
      "kind" => "crypto",
      "chain_id" => "eip155:8453",
      "asset_id" => ABI.address("usdc"),
      "symbol" => "USDC",
      "decimals" => 6
    }

    fiat = %{"kind" => "fiat", "currency" => "USD", "decimals" => 2}

    {:ok, intent} =
      Ramp.decode(%{
        "contract_version" => "ramp/1",
        "kind" => "intent",
        "direction" => "offramp",
        "crypto" => crypto,
        "fiat" => fiat,
        "exact" => %{"side" => "crypto", "money" => %{"asset" => crypto, "atomic" => "2000000"}},
        "recipient" => @owner
      })

    c = %{
      intent: intent,
      user: @owner,
      maker_rails: ["revolut"],
      maker_mapping: mapping,
      maker_indexer: indexer,
      checkpoint: Checkpoint.ETS.new(),
      chain_reader: reader,
      now: fn -> @now end,
      maker_registrations: %{
        "revolut" => %{
          own_account_verified: true,
          wallet: @owner,
          payee_hash: "0x" <> String.duplicate("3", 64)
        }
      },
      wallet: ReviewWallet,
      on_confirm: fn _, _ -> :approve end,
      ledger: start_supervised!({Ledger, table_name: :peer_live_ledger}),
      peer_cashout_policy: %SpendingPolicy{
        per_request_max: Decimal.new(10),
        session_max: Decimal.new(100),
        lifetime_max: Decimal.new(1000),
        approved_domains: ["peer.xyz"]
      }
    }

    seed(state)
    %{c: c, state: state}
  end

  defp default(%{"type" => "tuple", "components" => cs}),
    do: Map.new(cs, &{&1["name"], default(&1)})

  defp default(%{"type" => type}) do
    cond do
      String.ends_with?(type, "[]") -> []
      type == "address" -> @zero
      type == "bool" -> false
      type == "bytes" -> "0x"
      type == "bytes32" -> "0x" <> String.duplicate("0", 64)
      true -> 0
    end
  end

  defp put_read(pid, contract, name, args, value) do
    spec = ABI.function(contract, name)
    encoded = ABI.hex(ABI.encode(spec["outputs"], [value]))

    Agent.update(
      pid,
      &put_in(&1, [:reads, {ABI.address(contract), ABI.call(contract, name, args)}], encoded)
    )
  end

  defp token_read(pid, selector, args, amount) do
    data =
      selector <> Enum.map_join(args, &String.pad_leading(String.slice(&1, 2..-1//1), 64, "0"))

    Agent.update(
      pid,
      &put_in(&1, [:reads, {ABI.address("usdc"), data}], ABI.hex(<<amount::256>>))
    )
  end

  defp deposit_tuple(remaining \\ 2_000_000, outstanding \\ 0) do
    spec = hd(ABI.function("escrowV2", "getDeposit")["outputs"])

    Map.merge(default(spec), %{
      "depositor" => @owner,
      "token" => ABI.address("usdc"),
      "remainingDeposits" => remaining,
      "outstandingIntentAmount" => outstanding,
      "intentAmountRange" => %{"min" => 1_000_000, "max" => 5_000_000}
    })
  end

  defp seed(pid) do
    for contract <- ["escrowV2", "orchestratorV4"],
        do: put_read(pid, contract, "paused", [], false)

    token_read(pid, "0x70a08231", [@owner], 10_000_000)
    token_read(pid, "0xdd62ed3e", [@owner, ABI.address("escrowV2")], 3_000_000)
    put_read(pid, "escrowV2", "getDeposit", [7], deposit_tuple())
    put_read(pid, "escrowV2", "getDepositIntentHashes", [7], [])
    method = ABI.config()["rails"]["revolut"]["paymentMethodHash"]
    currency = ABI.config()["currencyHash"]
    put_read(pid, "escrowV2", "getDepositPaymentMethodActive", [7, method], true)
    put_read(pid, "escrowV2", "getDepositCurrencyListed", [7, method, currency], true)

    put_read(
      pid,
      "escrowV2",
      "getEffectiveRate",
      [7, method, currency],
      1_000_000_000_000_000_000
    )

    put_read(
      pid,
      "escrowV2",
      "getDepositCurrencyMinRate",
      [7, method, currency],
      1_000_000_000_000_000_000
    )

    put_read(pid, "escrowV2", "getDepositOracleRateConfig", [7, method, currency], %{
      "adapter" => @zero,
      "adapterConfig" => "0x",
      "spreadBps" => 0,
      "maxStaleness" => 0
    })

    viewer = default(hd(ABI.function("protocolViewerV4", "getDeposit")["outputs"]))

    put_read(
      pid,
      "protocolViewerV4",
      "getDeposit",
      [ABI.address("escrowV2"), 7],
      Map.merge(viewer, %{
        "depositId" => 7,
        "deposit" => deposit_tuple(),
        "availableLiquidity" => 2_000_000
      })
    )
  end

  defp template do
    id = "8453_" <> ABI.address("escrowV2") <> "_7"

    %{
      "DepositPaymentMethod" => [
        %{
          "depositId" => id,
          "depositIdOnContract" => "7",
          "paymentMethodHash" => ABI.config()["rails"]["revolut"]["paymentMethodHash"]
        }
      ],
      "MethodCurrency" => [%{"depositId" => id, "depositIdOnContract" => "7"}]
    }
  end

  defp index do
    %{
      "Deposit_by_pk" => %{
        "depositId" => "7",
        "chainId" => 8453,
        "escrowAddress" => ABI.address("escrowV2"),
        "depositor" => @owner,
        "token" => ABI.address("usdc"),
        "remainingDeposits" => "2000000",
        "outstandingIntentAmount" => "0",
        "totalAmountTaken" => "0",
        "totalWithdrawn" => "0",
        "blockNumber" => "100",
        "status" => "ACTIVE"
      },
      "Intent" => [],
      "DepositFundActivity" => []
    }
  end

  defp preview(c) do
    {:ok, [offer]} = Peer.capabilities(c)
    {:ok, preview} = Peer.preview(c.intent, offer.offer_id, offer.capability_revision, c)
    %{c | intent: c.intent} |> Map.put(:preview, preview)
  end

  defp reserve(c) do
    op = c.preview.operation_id
    snapshot = %Ramp.Snapshot{}

    :ok =
      Checkpoint.put(c.checkpoint, "peer_maker:" <> op, %{
        operation_ref: op,
        revision: "1",
        idempotency_key: "test",
        pending_action_ref: "action_synthetic",
        snapshot: snapshot
      })

    :ok = Mapping.put_maker(c, op, %{total: "2000000"})
    op
  end

  test "default discovery and preview use fresh maker evidence and approximate disclosures", %{
    c: c
  } do
    c = preview(c)
    assert c.preview.pay["atomic"] == "2000000"
    assert c.preview.receive["atomic"] == "200"
    assert "maker_estimate" in c.preview.disclosures["public_state"]
    assert {:ok, _} = Ramp.encode(c.preview)
    {:ok, [setup]} = Peer.capabilities(%{c | maker_registrations: %{}})
    assert setup.availability["state"] == "setup_required"
  end

  test "429 Retry-After blocks subsequent calls without sleeping", %{c: c, state: state} do
    Agent.update(state, &Map.put(&1, :rate_limit, "60"))
    assert {:ok, [offer]} = Peer.capabilities(c)
    assert offer.availability["state"] == "availability_unknown"
    calls = Agent.get(state, & &1.index_calls)
    assert {:ok, [_]} = Peer.capabilities(c)
    assert Agent.get(state, & &1.index_calls) == calls
  end

  test "default IO constructs exact plans and policy path asks existing signer", %{c: c} do
    c = preview(c)

    assert {:ok, snapshot} =
             Peer.approve(
               c.preview.operation_id,
               c.preview.quote_id,
               %{approved: true, expected_revision: "0", idempotency_key: "default_sign"},
               c
             )

    assert_received :sign_requested
    assert snapshot.peer["state"] == "action_required"

    assert {:ok, repeat} =
             Peer.approve(
               c.preview.operation_id,
               c.preview.quote_id,
               %{approved: true, expected_revision: "0", idempotency_key: "default_sign"},
               c
             )

    refute_received :sign_requested
    assert repeat == snapshot
  end

  for point <- [:before_reserve, :after_reserve, :after_claim, :after_mapping, :after_nonce_claim] do
    test "deposit approval recovers after a crash at #{point}", %{c: c, state: state} do
      c = preview(c)
      {_, table} = c.checkpoint
      c = %{c | checkpoint: {CrashCheckpoint, table}}
      op = c.preview.operation_id
      key = "peer_maker:" <> op
      cmd = %{approved: true, expected_revision: "0", idempotency_key: "interrupted"}
      point = unquote(point)

      {pid, monitor} =
        spawn_monitor(fn ->
          Process.put(CrashCheckpoint, &crash_at?(&1, point, key, op, c))
          Peer.approve(op, c.preview.quote_id, cmd, c)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

      assert {:ok, stored} = Checkpoint.fetch(c.checkpoint, key)
      assert_reservation(point, stored)
      snapshot = stored.snapshot
      assert {:ok, ^snapshot} = Peer.approve(op, c.preview.quote_id, cmd, c)

      assert_nonce_recovery(point, op, c, state)

      assert {:ok, restored} = Peer.status(op, c)
      assert_budget(c, 0)
      assert restored.peer["state"] == "action_required"
      assert "recover_peer" in restored.allowed_actions

      retry = %{cmd | expected_revision: restored.revision, idempotency_key: "fresh"}
      assert {:ok, _} = Peer.recover(op, "recover_peer", retry, c)
      assert_received :sign_requested
      refute_received :sign_requested
      assert Agent.get(state, & &1.broadcasts) == 0
    end
  end

  test "a crash after the budget debit can release it exactly once on restart", %{c: c} do
    c = preview(c)
    op = c.preview.operation_id
    cmd = %{approved: true, expected_revision: "0", idempotency_key: "budget_crash"}

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :approve -> Peer.approve(op, c.preview.quote_id, cmd, c)
        end
      end)

    event = [:raxol, :payments, :spend]
    handler = {__MODULE__, monitor}

    :ok =
      :telemetry.attach(handler, event, &__MODULE__.kill_after_debit/4, {c.ledger, pid})

    on_exit(fn -> :telemetry.detach(handler) end)
    send(pid, :approve)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    assert_budget(c, 2)
    refute_received :sign_requested

    # Pending cash-outs remain recoverable even if legacy intent tags are swept.
    assert 0 == Ledger.sweep_reservations(c.ledger)
    assert {:ok, %{peer: %{"state" => "action_required"}}} = Peer.status(op, c)
    assert_budget(c, 0)
    assert {:ok, _} = Peer.status(op, c)
    assert_budget(c, 0)
    assert length(Ledger.get_history(c.ledger, {:peer_cashout, :unknown})) == 2
  end

  @doc false
  def kill_after_debit(_, _, %{agent_id: {:peer_cashout, :unknown}}, {ledger, pid}) do
    if self() == ledger, do: Process.exit(pid, :kill)
  end

  def kill_after_debit(_, _, _, _), do: :ok

  test "a lost broadcast response keeps the cash-out budget reserved", %{c: c, state: state} do
    c = c |> Map.put(:maker_wallet, {DeferredWallet, c}) |> preview()
    op = c.preview.operation_id
    cmd = %{approved: true, expected_revision: "0", idempotency_key: "budget_broadcast"}
    assert {:requires_user, _, _} = Peer.approve(op, c.preview.quote_id, cmd, c)
    assert_received {:wallet_handoff, ^op, pending, plan}
    {:ok, mapping} = Mapping.fetch_maker(c, op)
    payload = "synthetic transaction"

    :ok =
      Mapping.put_maker(
        c,
        op,
        Map.merge(mapping, %{
          pending_action_ref: pending,
          pending_tx_hash: ABI.hash(payload),
          expected_to: plan.to,
          expected_input_hash: ABI.hash(ABI.unhex(plan.data))
        })
      )

    assert {:error, :lost_response} = MemoryChain.broadcast(state, 8453, payload)
    assert {:ok, %{peer: %{"state" => "in_doubt"}}} = Peer.status(op, c)
    assert_budget(c, 2)
    assert Agent.get(state, & &1.broadcasts) == 1
  end

  defp assert_budget(c, expected) do
    totals = Ledger.get_totals(c.ledger, {:peer_cashout, :unknown}, c.peer_cashout_policy)
    assert Decimal.equal?(totals.session, Decimal.new(expected))
    assert Decimal.equal?(totals.lifetime, Decimal.new(expected))
  end

  defp assert_nonce_recovery(:after_nonce_claim, op, c, state) do
    assert_budget(c, 2)
    Agent.update(state, &Map.put(&1, :finalized_nonce, "0x1"))
    assert {:ok, %{peer: %{"state" => "in_doubt"}}} = Peer.status(op, c)
    assert_budget(c, 2)
    Agent.update(state, &Map.put(&1, :finalized_nonce, "0x0"))
  end

  defp assert_nonce_recovery(_, _, _, _), do: :ok

  defp assert_reservation(:before_reserve, stored), do: assert(is_nil(stored.pending_action_ref))
  defp assert_reservation(_, stored), do: assert(is_binary(stored.pending_action_ref))

  defp crash_at?({:before_put, key, %{revision: "1"}}, :before_reserve, key, _, _), do: true
  defp crash_at?({:after_put, key, %{revision: "1"}}, :after_reserve, key, _, _), do: true
  defp crash_at?({:after_insert, "peer_command:" <> _, _}, :after_claim, _, _, _), do: true

  defp crash_at?({:before_put, key, %{revision: "1"}}, point, key, op, c) do
    {:ok, mapping} = Mapping.fetch_maker(c, op)

    case {point, mapping[:pending_kind]} do
      {:after_mapping, {:requested, :create_deposit}} -> true
      {:after_nonce_claim, {:nonce, :create_deposit, 0}} -> true
      _ -> false
    end
  end

  defp crash_at?(_, _, _, _, _), do: false

  test "a denied withdrawal leaves the existing deposit withdrawable", %{c: c, state: state} do
    c = preview(c)
    op = reserve(c)
    assert :ok = Mapping.put_maker(c, op, %{total: "2000000", deposit_id: "7"})
    {:ok, saved} = Checkpoint.fetch(c.checkpoint, "peer_maker:" <> op)
    :ok = Checkpoint.put(c.checkpoint, "peer_maker:" <> op, %{saved | pending_action_ref: nil})
    assert {:ok, processing} = Peer.status(op, c)
    assert processing.peer["state"] == "processing"

    deny = fn _, _ -> :deny end

    command = %{
      approved: true,
      expected_revision: processing.revision,
      idempotency_key: "deny_withdrawal",
      amount: "2000000"
    }

    assert {:ok, restored} = Peer.recover(op, "recover_peer", command, %{c | on_confirm: deny})
    assert restored.peer["state"] == "processing"
    assert "recover_peer" in restored.allowed_actions
    assert {:ok, %{peer: %{"state" => "processing"}}} = Peer.status(op, c)
    assert Agent.get(state, & &1.broadcasts) == 0
    refute_received :sign_requested
  end

  test "status checks a crash-window nonce before clearing the pending withdrawal", %{
    c: c,
    state: state
  } do
    c = preview(c)
    op = reserve(c)
    pending = "action_synthetic"

    assert :ok =
             Mapping.put_maker(c, op, %{
               total: "2000000",
               deposit_id: "7",
               owner: @owner,
               pending_action_ref: pending,
               pending_kind: {:nonce, :withdraw_unmatched, 0}
             })

    assert :ok = Mapping.claim_nonce(c.maker_mapping, @owner, 0, pending)
    Agent.update(state, &Map.put(&1, :finalized_nonce, "0x1"))
    assert {:ok, %{peer: %{"state" => "in_doubt"}}} = Peer.status(op, c)
    assert {:error, :nonce_reserved} = Mapping.claim_nonce(c.maker_mapping, @owner, 0, "other")

    Agent.update(state, &Map.put(&1, :finalized_nonce, "0x0"))
    assert {:ok, %{peer: %{"state" => "processing"}}} = Peer.status(op, c)
    assert :ok = Mapping.claim_nonce(c.maker_mapping, @owner, 0, "other")
    assert Agent.get(state, & &1.broadcasts) == 0
  end

  test "status repairs a checkpoint that advanced ahead of the mapping", %{c: c} do
    c = preview(c)
    op = reserve(c)

    assert :ok =
             Mapping.put_maker(c, op, %{
               total: "2000000",
               deposit_id: "7",
               pending_action_ref: "action_previous",
               pending_tx_hash: ABI.hash("previous finalized action"),
               pending_resolved: true
             })

    assert {:ok, restored} = Peer.status(op, c)
    assert restored.peer["state"] == "processing"
    assert "recover_peer" in restored.allowed_actions
  end

  test "wallet refuses changed calldata and denied approval before signing", %{c: c} do
    c = preview(c)
    op = reserve(c)
    terms = %{amount: "2000000", preview: c.preview, intent: c.intent}
    assert {:ok, plan} = LiveIO.prepare(c, op, :create_deposit, terms, %{total: "2000000"})
    assert :ok = Wallet.validate(c, plan, Map.put(terms, :action, :create_deposit))
    expired = %{terms | preview: %{terms.preview | expires_at: "2026-11-16T11:59:00Z"}}

    assert {:error, :capability_unavailable} =
             LiveIO.prepare(c, op, :create_deposit, expired, %{total: "2000000"})

    assert {:error, :wallet_unavailable} =
             Wallet.validate(c, %{plan | data: "0x00"}, Map.put(terms, :action, :create_deposit))

    assert {:error, :wallet_unavailable} =
             Wallet.request(%{c | on_confirm: fn _, _ -> :deny end}, op, "action_synthetic", plan)

    refute_received :sign_requested
  end

  test "deposit balances are reconciled against indexer and protocol", %{c: c, state: state} do
    facts = LiveReads.deposit!(c, 7, @owner)
    assert facts.remaining == "2000000" and facts.unmatched == "2000000"
    Agent.update(state, &put_in(&1, [:index, "Deposit_by_pk", "remainingDeposits"], "1999999"))
    c = preview(c)
    op = reserve(c)
    :ok = Mapping.put_maker(c, op, %{total: "2000000", deposit_id: "7"})

    assert {:error, :capability_unavailable} =
             LiveIO.reconcile(c, op, %{total: "2000000", deposit_id: "7", pending_action_ref: nil})
  end

  test "fresh allowance yields a separately named bounded approval when needed", %{
    c: c,
    state: state
  } do
    c = preview(c)
    op = reserve(c)
    token_read(state, "0xdd62ed3e", [@owner, ABI.address("escrowV2")], 0)
    terms = %{amount: "2000000", preview: c.preview, intent: c.intent}
    assert {:ok, plan} = LiveIO.prepare(c, op, :create_deposit, terms, %{total: "2000000"})
    assert plan.action == :approve_usdc
    assert plan.data == Plans.approval(2_000_000).data
  end

  test "protocol active intents and reserved liquidity narrow withdrawals", %{c: c, state: state} do
    hash = ABI.hash("synthetic active intent")
    put_read(state, "escrowV2", "getDeposit", [7], deposit_tuple(1_500_000, 500_000))
    put_read(state, "escrowV2", "getDepositIntentHashes", [7], [hash])
    intent = default(hd(ABI.function("orchestratorV4", "getIntent")["outputs"]))

    put_read(
      state,
      "orchestratorV4",
      "getIntent",
      [hash],
      Map.merge(intent, %{
        "escrow" => ABI.address("escrowV2"),
        "depositId" => 7,
        "amount" => 500_000
      })
    )

    viewer = default(hd(ABI.function("protocolViewerV4", "getDeposit")["outputs"]))

    put_read(
      state,
      "protocolViewerV4",
      "getDeposit",
      [ABI.address("escrowV2"), 7],
      Map.merge(viewer, %{
        "depositId" => 7,
        "deposit" => deposit_tuple(1_500_000, 500_000),
        "availableLiquidity" => 1_200_000
      })
    )

    Agent.update(state, fn state ->
      state
      |> put_in([:index, "Deposit_by_pk", "remainingDeposits"], "1500000")
      |> put_in([:index, "Deposit_by_pk", "outstandingIntentAmount"], "500000")
      |> put_in([:index, "Intent"], [
        %{
          "intentHash" => hash,
          "amount" => "500000",
          "status" => "SIGNALED",
          "releasedAmount" => nil,
          "orchestratorAddress" => ABI.address("orchestratorV4")
        }
      ])
    end)

    facts = LiveReads.deposit!(c, 7, @owner)

    assert facts.remaining == "2000000" and facts.unmatched == "1200000" and
             facts.active_intents == 1

    assert {:error, :capability_unavailable} =
             LiveIO.prepare(c, "op_synthetic", :withdraw_unmatched, %{amount: "2000000"}, %{
               deposit_id: "7",
               total: "2000000"
             })
  end

  test "verified fills and withdrawals stay separate and conserve funds", %{c: c, state: state} do
    put_read(state, "escrowV2", "getDeposit", [7], deposit_tuple(0, 0))

    Agent.update(state, fn state ->
      state
      |> put_in([:index, "Deposit_by_pk", "remainingDeposits"], "0")
      |> put_in([:index, "Deposit_by_pk", "totalAmountTaken"], "500000")
      |> put_in([:index, "Deposit_by_pk", "totalWithdrawn"], "1500000")
      |> put_in([:index, "Deposit_by_pk", "status"], "WITHDRAWN")
      |> put_in([:index, "Intent"], [%{"status" => "FULFILLED", "releasedAmount" => "500000"}])
      |> put_in([:index, "DepositFundActivity"], [
        %{"activityType" => "WITHDRAWN", "amount" => "1500000", "blockNumber" => "100"}
      ])
    end)

    facts = LiveReads.deposit!(c, 7, @owner)
    assert facts.remaining == "0" and facts.filled == "500000" and facts.withdrawn == "1500000"
  end

  test "final receipt must match the pending action, owner, calldata and deposit event", %{
    c: c,
    state: state
  } do
    c = preview(c)
    op = reserve(c)

    plan =
      Plans.deposit(2_000_000, "revolut", c.maker_registrations["revolut"].payee_hash, %{
        minimum: 1_000_000,
        maximum: 5_000_000,
        rate: 1_000_000_000_000_000_000
      })

    hash = ABI.hash("synthetic receipt")
    event = ABI.function("escrowV2", "DepositReceived")

    topic =
      ABI.hash("DepositReceived(" <> Enum.map_join(event["inputs"], ",", &ABI.type_name/1) <> ")")

    word = fn address -> "0x" <> String.pad_leading(String.slice(address, 2..-1//1), 64, "0") end

    data =
      ABI.encode(Enum.reject(event["inputs"], & &1["indexed"]), [
        2_000_000,
        %{"min" => 1_000_000, "max" => 2_000_000},
        @zero,
        ABI.address("intentGuardian")
      ])

    receipt = %{
      "transactionHash" => hash,
      "blockNumber" => "0x64",
      "status" => "0x1",
      "logs" => [
        %{
          "address" => ABI.address("escrowV2"),
          "topics" => [topic, ABI.hex(<<7::256>>), word.(@owner), word.(ABI.address("usdc"))],
          "data" => ABI.hex(data)
        }
      ]
    }

    transaction = %{
      "chainId" => "0x2105",
      "from" => @owner,
      "to" => plan.to,
      "input" => plan.data,
      "value" => "0x0"
    }

    Agent.update(
      state,
      &Map.merge(&1, %{transactions: %{hash => transaction}, receipts: %{hash => receipt}})
    )

    mapping = %{
      total: "2000000",
      owner: @owner,
      pending_tx_hash: hash,
      pending_kind: :create_deposit,
      pending_action_ref: "action_synthetic",
      requested_action_ref: "action_synthetic",
      expected_to: plan.to,
      expected_input_hash: ABI.hash(ABI.unhex(plan.data))
    }

    :ok = Mapping.put_maker(c, op, mapping)
    assert {:ok, %{state: :confirmed, deposit_id: "7"}} = LiveIO.reconcile(c, op, mapping)

    assert {:error, :capability_unavailable} =
             LiveIO.reconcile(c, op, %{mapping | requested_action_ref: "action_other"})

    Agent.update(state, &put_in(&1, [:receipts, hash, "status"], "0x0"))
    assert {:ok, %{state: :reverted}} = LiveIO.reconcile(c, op, mapping)
    Agent.update(state, &put_in(&1, [:receipts, hash, "status"], "0x1"))

    Agent.update(state, &put_in(&1, [:transactions, hash, "input"], "0x00"))
    assert {:error, :capability_unavailable} = LiveIO.reconcile(c, op, mapping)
  end

  test "HTTP-date Retry-After permits another request only at its deadline", %{state: state} do
    base = DateTime.to_unix(@now, :millisecond)
    Agent.update(state, &Map.put(&1, :clock, base))

    indexer =
      start_supervised!(%{
        id: :date_indexer,
        start:
          {Indexer, :start_link,
           [
             [
               now: fn -> Agent.get(state, & &1.clock) end,
               req_options: [
                 plug: fn conn ->
                   count =
                     Agent.get_and_update(state, fn s ->
                       {s.index_calls, %{s | index_calls: s.index_calls + 1}}
                     end)

                   if count == 0,
                     do:
                       conn
                       |> Plug.Conn.put_resp_header(
                         "retry-after",
                         "Mon, 16 Nov 2026 12:01:00 GMT"
                       )
                       |> Plug.Conn.send_resp(429, ""),
                     else: Plug.Conn.send_resp(conn, 200, ~s({"data":{}}))
                 end
               ]
             ]
           ]},
        type: :worker
      })

    assert {:error, :rate_limited} = Indexer.query(indexer, "query {}", %{})
    Agent.update(state, &Map.put(&1, :clock, base + 59_999))
    assert {:error, :rate_limited} = Indexer.query(indexer, "query {}", %{})
    assert Agent.get(state, & &1.index_calls) == 1
    Agent.update(state, &Map.put(&1, :clock, base + 60_000))
    assert {:ok, %{}} = Indexer.query(indexer, "query {}", %{})
    assert Agent.get(state, & &1.index_calls) == 2
  end

  test "existing JSONRPC reader exposes bounded protocol reads without raw failures" do
    reader =
      JSONRPC.new(
        chains: %{8453 => "https://unused.invalid"},
        req_options: [
          plug: fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            method = Jason.decode!(body)["method"]

            response =
              if method == "eth_chainId",
                do: %{result: "0x2105"},
                else: %{error: %{code: -32_000, message: "synthetic rejected response"}}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(response))
          end
        ]
      )

    assert {:ok, "0x2105"} = ChainReader.request(reader, 8453, "eth_chainId", [])
    assert {:error, :chain_unavailable} = ChainReader.request(reader, 8453, "eth_call", [])

    assert {:error, :unsupported_read} =
             ChainReader.request(reader, 8453, "eth_sendRawTransaction", [])
  end

  test "confirmed allowance resumes the same operation with a fresh separately approved deposit",
       %{c: c, state: state} do
    c = preview(c)
    c = Map.put(c, :maker_wallet, {DeferredWallet, c})
    token_read(state, "0xdd62ed3e", [@owner, ABI.address("escrowV2")], 0)
    op = c.preview.operation_id

    assert {:requires_user, approval, _} =
             Peer.approve(
               op,
               c.preview.quote_id,
               %{approved: true, expected_revision: "0", idempotency_key: "allowance"},
               c
             )

    assert approval.action == "approve_usdc"
    assert_received {:wallet_handoff, ^op, pending, plan}
    hash = ABI.hash("synthetic allowance receipt")

    transaction = %{
      "chainId" => "0x2105",
      "from" => @owner,
      "to" => plan.to,
      "input" => plan.data,
      "value" => "0x0"
    }

    receipt = %{
      "transactionHash" => hash,
      "blockNumber" => "0x64",
      "status" => "0x1",
      "logs" => []
    }

    Agent.update(
      state,
      &Map.merge(&1, %{transactions: %{hash => transaction}, receipts: %{hash => receipt}})
    )

    {:ok, mapping} = Mapping.fetch_maker(c, op)

    :ok =
      Mapping.put_maker(
        c,
        op,
        Map.merge(mapping, %{
          owner: @owner,
          pending_tx_hash: hash,
          pending_kind: :approve_usdc,
          pending_action_ref: pending,
          expected_to: plan.to,
          expected_input_hash: ABI.hash(ABI.unhex(plan.data))
        })
      )

    token_read(state, "0xdd62ed3e", [@owner, ABI.address("escrowV2")], 3_000_000)
    assert {:ok, action_required} = Peer.status(op, c)
    assert action_required.peer["state"] == "action_required"
    entries = Ledger.get_history(c.ledger, {:peer_cashout, :unknown})

    assert Decimal.equal?(
             Enum.reduce(entries, Decimal.new(0), &Decimal.add(&1.amount, &2)),
             Decimal.new(0)
           )

    {:ok, [offer]} = Peer.capabilities(c)

    assert {:ok, fresh} =
             Peer.preview(
               c.intent,
               offer.offer_id,
               offer.capability_revision,
               Map.put(c, :resume_operation_ref, op)
             )

    assert fresh.operation_id == op and fresh.quote_id != c.preview.quote_id
    c = %{c | preview: fresh}

    assert {:requires_user, create, _} =
             Peer.recover(
               op,
               "recover_peer",
               %{
                 approved: true,
                 expected_revision: action_required.revision,
                 idempotency_key: "create_after_allowance",
                 quote_id: fresh.quote_id
               },
               c
             )

    assert create.action == "create_deposit"
    assert_received {:wallet_handoff, ^op, _, %{action: :create_deposit}}
    assert {:ok, uncertain} = Peer.status(op, c)
    assert uncertain.allowed_actions == ["check_status"]

    assert {:error, :capability_unavailable} =
             Peer.preview(
               c.intent,
               offer.offer_id,
               offer.capability_revision,
               Map.put(c, :resume_operation_ref, op)
             )
  end

  test "changed maker bounds require a new review even when the displayed estimate is unchanged",
       %{c: c, state: state} do
    c = preview(c)
    op = reserve(c)
    changed = put_in(deposit_tuple(), ["intentAmountRange", "min"], 500_000)
    put_read(state, "escrowV2", "getDeposit", [7], changed)
    terms = %{amount: "2000000", preview: c.preview, intent: c.intent}

    assert {:error, :capability_unavailable} =
             LiveIO.prepare(c, op, :create_deposit, terms, %{total: "2000000"})
  end

  test "missing chain evidence produces unknown capabilities", %{c: c, state: state} do
    Agent.update(state, &Map.put(&1, :fault, "eth_chainId"))
    assert {:ok, [offer]} = Peer.capabilities(c)
    assert offer.availability["state"] == "availability_unknown"
  end
end

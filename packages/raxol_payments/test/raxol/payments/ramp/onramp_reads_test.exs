defmodule Raxol.Payments.Ramp.Peer.OnrampReadsTest do
  use ExUnit.Case, async: false
  alias Raxol.Payments.{ChainReader, Checkpoint, Ramp, Ramps, SpendingPolicy}
  alias Raxol.Payments.Ramp.Peer.{ABI, Indexer, LiveReads, Mapping, OnrampReads}
  @now ~U[2026-11-16 12:00:00Z]
  @owner "0x0000000000000000000000000000000000000001"
  @rate 1_000_000_000_000_000_000
  @signal_amount 100_000_000
  @receive_amount 99_000_000
  @fixture Path.expand("../../../fixtures/ramp/peer_quote.json", __DIR__)
  @zero "0x0000000000000000000000000000000000000000"

  defmodule MemoryChain do
    @behaviour ChainReader
    def get_receipt(_, _, _), do: {:error, :not_found}
    def get_balance(_, _, _), do: {:error, :not_found}
    def get_erc20_balance(_, _, _, _), do: {:error, :not_found}
    def request(pid, 8453, method, args), do: Agent.get(pid, &Map.fetch!(&1.rpc, {method, args}))
  end

  setup tags do
    tmp = Path.join(System.tmp_dir!(), "peer-onramp-#{System.unique_integer([:positive])}")

    mapping =
      start_supervised!({Mapping, path: Path.join(tmp, "mapping.dets"), name: :peer_onramp_reads})

    on_exit(fn -> File.rm_rf!(tmp) end)
    state = start_supervised!({Agent, fn -> %{rpc: %{}, index: %{}} end})

    indexer =
      start_supervised!(
        {Indexer,
         req_options: [
           plug: fn conn ->
             data = Agent.get(state, & &1.index)
             Plug.Conn.send_resp(conn, 200, Jason.encode!(%{data: data}))
           end
         ]}
      )

    c = %{
      maker_mapping: mapping,
      maker_indexer: indexer,
      user: @owner,
      checkpoint: Checkpoint.ETS.new(),
      policy: SpendingPolicy.unrestricted(),
      on_confirm: fn _, _ -> :approve end,
      widget: fn _, _, _ -> Map.get(tags, :widget_reply, :pending) end,
      now: fn -> @now end,
      chain_reader: {MemoryChain, state}
    }

    c = preview(c)
    op = c.preview.operation_id
    intent = ABI.hash("synthetic intent")
    signal = ABI.hash("synthetic signal")
    settlement = ABI.hash("synthetic settlement")

    assert {:ok, pending} =
             Ramps.run(op, %{quote_id: c.preview.quote_id, command: command()}, c)

    assert pending.peer["state"] == "in_doubt"

    :ok =
      OnrampReads.track(c, op, %{
        intent_hash: intent,
        signal_tx_hash: signal,
        settlement_tx_hash: settlement
      })

    put_rpc(state, "eth_chainId", [], "0x2105")
    put_rpc(state, "eth_blockNumber", [], "0x66")

    put_rpc(state, "eth_getBlockByNumber", ["0x64", false], %{
      "number" => "0x64",
      "timestamp" => LiveReads.hex(DateTime.to_unix(@now))
    })

    put_rpc(state, "eth_getBlockByNumber", ["finalized", false], %{"number" => "0x64"})

    put_signal_block(state, @now)

    test = %{c: c, state: state, op: op, intent: intent, signal: signal, settlement: settlement}
    put_signal(test)
    test
  end

  defp command, do: %{expected_revision: "0", idempotency_key: "synthetic_approval"}

  defp preview(c) do
    body = @fixture |> File.read!() |> Jason.decode!()

    body =
      update_in(body, ["responseObject", "platformQuotes", Access.at(0), "bestQuote"], fn quote ->
        quote
        |> Map.put("signalIntentAmount", Integer.to_string(@signal_amount))
        |> Map.put("conversionRate", Integer.to_string(@rate))
        |> put_in(["intent", "depositId"], "7")
      end)

    fiat = %{"kind" => "fiat", "currency" => "USD", "decimals" => 2}

    intent = %Ramp.Intent{
      contract_version: "ramp/1",
      kind: "intent",
      direction: "onramp",
      recipient: @owner,
      exact: %{"side" => "fiat", "money" => %{"asset" => fiat, "atomic" => "10000"}},
      fiat: fiat,
      crypto: %{
        "kind" => "crypto",
        "chain_id" => "eip155:8453",
        "asset_id" => ABI.address("usdc"),
        "symbol" => "USDC",
        "decimals" => 6
      }
    }

    context =
      Map.merge(c, %{
        intent: intent,
        interaction_ready: true,
        orchestrator: body["responseObject"]["orchestratorAddress"],
        ready_rails: ["wise"],
        req_options: [
          plug: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("date", "Mon, 16 Nov 2026 12:00:00 GMT")
            |> Plug.Conn.send_resp(200, Jason.encode!(body))
          end
        ]
      })

    assert {:ok, [offer]} = Ramps.discover(intent, context)

    assert {:ok, preview} =
             Ramps.preview(intent, offer.offer_id, offer.capability_revision, context)

    Map.put(context, :preview, preview)
  end

  defp put_signal_block(state, time) do
    put_rpc(state, "eth_getBlockByNumber", ["0x63", false], %{
      "number" => "0x63",
      "hash" => ABI.hash("synthetic block"),
      "timestamp" => LiveReads.hex(DateTime.to_unix(time))
    })
  end

  defp put_signal(test, overrides \\ []) do
    signal_log =
      event(
        "IntentSignaled",
        [
          test.intent,
          word(ABI.address("escrowV2")),
          ABI.hex(<<Keyword.get(overrides, :deposit, 7)::256>>)
        ],
        [
          Keyword.get(overrides, :method, ABI.hash("wise")),
          @owner,
          @owner,
          Keyword.get(overrides, :amount, @signal_amount),
          Keyword.get(overrides, :currency, ABI.hash("USD")),
          Keyword.get(overrides, :rate, @rate),
          DateTime.to_unix(@now),
          ABI.hash("synthetic group"),
          @zero
        ]
      )

    signal_receipt =
      receipt(test.signal, [signal_log])
      |> Map.put("blockNumber", "0x63")
      |> Map.put("blockHash", ABI.hash("synthetic block"))

    put_rpc(test.state, "eth_getTransactionReceipt", [test.signal], signal_receipt)
  end

  defp word(address), do: "0x" <> String.pad_leading(String.slice(address, 2..-1//1), 64, "0")

  defp put_rpc(pid, method, args, value),
    do: Agent.update(pid, &put_in(&1, [:rpc, {method, args}], {:ok, value}))

  defp receipt(hash, logs),
    do: %{"transactionHash" => hash, "status" => "0x1", "blockNumber" => "0x64", "logs" => logs}

  defp event(name, topics, values) do
    spec = ABI.function("orchestratorV4", name)
    topic = ABI.hash(name <> "(" <> Enum.map_join(spec["inputs"], ",", &ABI.type_name/1) <> ")")

    %{
      "address" => ABI.address("orchestratorV4"),
      "topics" => [topic | topics],
      "data" => ABI.hex(ABI.encode(Enum.reject(spec["inputs"], & &1["indexed"]), values))
    }
  end

  defp fulfilled(test, destination \\ @owner) do
    %{state: pid, intent: hash, settlement: tx} = test
    fulfillment = event("IntentFulfilled", [hash, word(destination)], [@receive_amount, @owner])

    transfer = %{
      "address" => ABI.address("usdc"),
      "topics" => [
        ABI.hash("Transfer(address,address,uint256)"),
        word(ABI.address("escrowV2")),
        word(@owner)
      ],
      "data" => ABI.hex(<<@receive_amount::256>>)
    }

    Agent.update(
      pid,
      &Map.put(&1, :index, %{
        "Intent" => [
          %{
            "intentHash" => hash,
            "amount" => Integer.to_string(@signal_amount),
            "releasedAmount" => Integer.to_string(@receive_amount),
            "status" => "FULFILLED",
            "orchestratorAddress" => ABI.address("orchestratorV4")
          }
        ],
        "Orchestrator_V21_IntentFulfilled" => [
          %{
            "intentHash" => hash,
            "amount" => Integer.to_string(@receive_amount),
            "fundsTransferredTo" => destination
          }
        ]
      })
    )

    put_rpc(pid, "eth_getTransactionReceipt", [tx], receipt(tx, [fulfillment, transfer]))
  end

  test "an oversized signal from the same wallet cannot resolve the reviewed onramp", t do
    fulfilled(t)
    put_signal(t, amount: @signal_amount + 1)
    assert {:ok, :in_doubt} = OnrampReads.reconcile(t.c, t.op)
  end

  test "wrong signal terms and blocks outside the approval window stay in doubt", t do
    fulfilled(t)

    for mismatch <- [
          [method: ABI.hash("other rail")],
          [currency: ABI.hash("EUR")],
          [rate: @rate - 1],
          [rate: @rate + 1],
          [deposit: 8]
        ] do
      put_signal(t, mismatch)
      assert {:ok, :in_doubt} = OnrampReads.reconcile(t.c, t.op)
    end

    put_signal(t)

    for offset <- [-1, 301] do
      put_signal_block(t.state, DateTime.add(@now, offset))
      assert {:ok, :in_doubt} = OnrampReads.reconcile(t.c, t.op)
    end

    put_signal_block(t.state, DateTime.add(@now, 300))
    assert {:ok, :completed} = OnrampReads.reconcile(t.c, t.op)
  end

  @tag widget_reply: :ready
  test "matching live signal enables the next stage without exposing the private binding", t do
    fulfilled(t)
    Agent.update(t.state, &put_in(&1, [:index, "Intent", Access.at(0), "status"], "SIGNALED"))

    put_live_intent(t, @rate + 1)
    assert {:ok, :in_doubt} = OnrampReads.reconcile(t.c, t.op)

    put_live_intent(t, @rate)
    assert {:requires_user, action, snapshot} = Ramps.status(t.op, t.c)

    assert snapshot.peer == %{
             "name" => "peer",
             "state" => "action_required",
             "recoverable" => false
           }

    assert Enum.sort(Map.keys(action)) == [:action_ref, :code, :instruction]

    for public <- [Ramp.to_wire(t.c.preview), Ramp.to_wire(snapshot), action],
        private <-
          ~w(signal_amount conversion_rate deposit_id payment_method fiat_currency approved_at) do
      refute String.contains?(Jason.encode!(public), private)
    end
  end

  defp put_live_intent(t, rate) do
    fields = %{
      "owner" => @owner,
      "to" => @owner,
      "escrow" => ABI.address("escrowV2"),
      "depositId" => 7,
      "amount" => @signal_amount,
      "timestamp" => DateTime.to_unix(@now),
      "paymentMethod" => ABI.hash("wise"),
      "fiatCurrency" => ABI.hash("USD"),
      "conversionRate" => rate,
      "payeeId" => ABI.hex(<<0::256>>),
      "referralFees" => [],
      "payerCommitment" => ABI.hex(<<0::256>>),
      "takerWhitelisted" => false,
      "arbitrator" => @zero
    }

    spec = ABI.function("orchestratorV4", "getIntent")

    args = [
      %{
        to: ABI.address("orchestratorV4"),
        data: ABI.call("orchestratorV4", "getIntent", [t.intent])
      },
      "0x64"
    ]

    put_rpc(t.state, "eth_call", args, ABI.hex(ABI.encode(spec["outputs"], [fields])))
  end

  test "final Base fulfillment and matching public indexer resolve the original onramp", t do
    fulfilled(t)
    assert {:ok, :completed} = OnrampReads.reconcile(t.c, t.op)

    Agent.update(
      t.state,
      &put_in(&1, [:index, "Intent", Access.at(0), "releasedAmount"], "999999")
    )

    assert {:ok, :in_doubt} = OnrampReads.reconcile(t.c, t.op)
  end

  test "missing, reverted and unfinalized receipts remain unknown", t do
    fulfilled(t)

    for value <- [
          nil,
          %{"status" => "0x0"},
          %{
            "transactionHash" => t.settlement,
            "status" => "0x1",
            "blockNumber" => "0x65",
            "logs" => []
          }
        ] do
      put_rpc(t.state, "eth_getTransactionReceipt", [t.settlement], value)
      assert {:ok, :in_doubt} = OnrampReads.reconcile(t.c, t.op)
    end
  end

  test "held payout becomes completed only after the finalized vault lock clears", t do
    vault = ABI.address("stakeVaultV2")
    fulfilled(t, vault)

    {:ok, original} =
      Agent.get(t.state, &Map.fetch!(&1.rpc, {"eth_getTransactionReceipt", [t.settlement]}))

    deferred =
      event("IntentPayoutDeferred", [t.intent, word(@owner), word(vault)], [@receive_amount])

    put_rpc(t.state, "eth_getTransactionReceipt", [t.settlement], %{
      original
      | "logs" => original["logs"] ++ [deferred]
    })

    spec = ABI.function("stakeVaultV2", "locks")
    params = [%{to: vault, data: ABI.call("stakeVaultV2", "locks", [t.intent])}, "0x64"]

    put_rpc(
      t.state,
      "eth_call",
      params,
      ABI.hex(ABI.encode(spec["outputs"], [@owner, @receive_amount, 100]))
    )

    assert {:ok, :held} = OnrampReads.reconcile(t.c, t.op)
    put_rpc(t.state, "eth_call", params, ABI.hex(ABI.encode(spec["outputs"], [@zero, 0, 0])))
    assert {:ok, :completed} = OnrampReads.reconcile(t.c, t.op)
  end

  test "trusted tracking refuses replacement hashes and changed wallets", t do
    assert {:error, :session_conflict} =
             OnrampReads.track(t.c, t.op, %{intent_hash: ABI.hash("different")})

    other = %{t.c | user: "0x0000000000000000000000000000000000000002"}
    assert {:error, :session_conflict} = OnrampReads.track(other, t.op, %{intent_hash: t.intent})
    assert {:ok, :in_doubt} = OnrampReads.reconcile(other, t.op)
    assert {:error, :session_conflict} = OnrampReads.track(t.c, t.op, %{unexpected: "value"})
  end
end

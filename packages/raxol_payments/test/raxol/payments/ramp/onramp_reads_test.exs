defmodule Raxol.Payments.Ramp.Peer.OnrampReadsTest do
  use ExUnit.Case, async: false
  alias Raxol.Payments.ChainReader
  alias Raxol.Payments.Ramp.Peer.{ABI, Indexer, LiveReads, Mapping, OnrampReads}
  @now ~U[2026-11-16 12:00:00Z]
  @owner "0x0000000000000000000000000000000000000001"
  @zero "0x0000000000000000000000000000000000000000"

  defmodule MemoryChain do
    @behaviour ChainReader
    def get_receipt(_, _, _), do: {:error, :not_found}
    def get_balance(_, _, _), do: {:error, :not_found}
    def get_erc20_balance(_, _, _, _), do: {:error, :not_found}
    def request(pid, 8453, method, args), do: Agent.get(pid, &Map.fetch!(&1.rpc, {method, args}))
  end

  setup do
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
      intent: %{recipient: @owner},
      now: fn -> @now end,
      chain_reader: {MemoryChain, state}
    }

    op = "op_synthetic"
    intent = ABI.hash("synthetic intent")
    signal = ABI.hash("synthetic signal")
    settlement = ABI.hash("synthetic settlement")
    :ok = OnrampReads.reserve(c, op, %{receive: %{"atomic" => "1000000"}})

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

    signal_log =
      event("IntentSignaled", [intent, word(ABI.address("escrowV2")), ABI.hex(<<7::256>>)], [
        ABI.hash("synthetic rail"),
        @owner,
        @owner,
        1_000_000,
        ABI.hash("USD"),
        1,
        1,
        ABI.hash("synthetic group"),
        @zero
      ])

    put_rpc(state, "eth_getTransactionReceipt", [signal], receipt(signal, [signal_log]))
    %{c: c, state: state, op: op, intent: intent, settlement: settlement}
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
    fulfillment = event("IntentFulfilled", [hash, word(destination)], [1_000_000, @owner])

    transfer = %{
      "address" => ABI.address("usdc"),
      "topics" => [
        ABI.hash("Transfer(address,address,uint256)"),
        word(ABI.address("escrowV2")),
        word(@owner)
      ],
      "data" => ABI.hex(<<1_000_000::256>>)
    }

    Agent.update(
      pid,
      &Map.put(&1, :index, %{
        "Intent" => [
          %{
            "intentHash" => hash,
            "amount" => "1000000",
            "releasedAmount" => "1000000",
            "status" => "FULFILLED",
            "orchestratorAddress" => ABI.address("orchestratorV4")
          }
        ],
        "Orchestrator_V21_IntentFulfilled" => [
          %{"intentHash" => hash, "amount" => "1000000", "fundsTransferredTo" => destination}
        ]
      })
    )

    put_rpc(pid, "eth_getTransactionReceipt", [tx], receipt(tx, [fulfillment, transfer]))
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

    deferred = event("IntentPayoutDeferred", [t.intent, word(@owner), word(vault)], [1_000_000])

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
      ABI.hex(ABI.encode(spec["outputs"], [@owner, 1_000_000, 100]))
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

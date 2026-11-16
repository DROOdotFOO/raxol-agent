defmodule Raxol.Payments.Ramp.PeerMakerTest do
  use ExUnit.Case, async: false
  alias Raxol.Payments.{Checkpoint, Ledger, SpendingPolicy}
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer
  alias Raxol.Payments.Ramp.Peer.Mapping
  @now ~U[2026-11-16 12:00:00Z]

  defmodule MemoryIO do
    @behaviour Peer.MakerIO
    @behaviour Peer.MakerWallet
    def prepare(pid, operation, action, terms, _mapping) do
      Agent.update(
        pid,
        &Map.update!(&1, :prepared, fn items -> [{operation, action} | items] end)
      )

      {:ok, %{action: action, amount: terms.amount}}
    end

    def validate(pid, plan, terms) do
      assert plan.amount == terms.amount
      Agent.get(pid, & &1.validation)
    end

    def request(pid, operation, action_ref, _plan) do
      Agent.update(
        pid,
        &Map.update!(&1, :requests, fn items -> [{operation, action_ref} | items] end)
      )

      case Agent.get(pid, & &1.request) do
        :lost -> raise "synthetic transport failure"
        result -> result
      end
    end

    def reconcile(pid, _, mapping) do
      Agent.update(pid, &Map.put(&1, :last_pending, mapping.requested_action_ref))
      Agent.get(pid, & &1.facts)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "peer-maker-#{System.unique_integer([:positive])}")

    mapping =
      start_supervised!({Mapping, path: Path.join(tmp, "mapping.dets"), name: :peer_maker_test})

    on_exit(fn -> File.rm_rf!(tmp) end)

    fake =
      start_supervised!(
        {Agent,
         fn ->
           %{
             prepared: [],
             requests: [],
             request: :ok,
             validation: :ok,
             facts: {:ok, %{state: :pending}}
           }
         end}
      )

    ledger = start_supervised!({Ledger, table_name: :peer_maker_ledger})

    crypto = %{
      "kind" => "crypto",
      "chain_id" => "eip155:8453",
      "asset_id" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "symbol" => "USDC",
      "decimals" => 6
    }

    fiat = %{"kind" => "fiat", "currency" => "USD", "decimals" => 2}

    {:ok, intent} =
      Ramp.decode(%{
        "contract_version" => "ramp/1",
        "kind" => "intent",
        "direction" => "offramp",
        "fiat" => fiat,
        "crypto" => crypto,
        "exact" => %{"side" => "crypto", "money" => %{"asset" => crypto, "atomic" => "1000000"}},
        "recipient" => "0x0000000000000000000000000000000000000001"
      })

    {:ok, preview} =
      Ramp.decode(%{
        "contract_version" => "ramp/1",
        "kind" => "preview",
        "operation_id" => "op_synthetic",
        "quote_id" => "quote_synthetic",
        "offer_id" => "offer_synthetic",
        "capability_revision" => "revision_synthetic",
        "request_digest" => "0x" <> String.duplicate("1", 64),
        "pay" => %{"asset" => crypto, "atomic" => "1000000"},
        "receive" => %{"asset" => fiat, "atomic" => "100"},
        "fees" => [],
        "expires_at" => "2026-11-16T12:01:00Z",
        "leg_order" => ["peer"],
        "disclosures" => %{
          "public_state" => ["base_settlement"],
          "identity_visible_to" => ["fiat_counterparty"],
          "liveness_dependencies" => ["peer"]
        }
      })

    context = %{
      checkpoint: Checkpoint.ETS.new(),
      maker_mapping: mapping,
      maker_io: {MemoryIO, fake},
      maker_wallet: {MemoryIO, fake},
      ledger: ledger,
      peer_cashout_policy: %SpendingPolicy{
        per_request_max: Decimal.new(10),
        session_max: Decimal.new(100),
        lifetime_max: Decimal.new(1000),
        approved_domains: ["peer.xyz"]
      },
      now: fn -> @now end,
      intent: intent,
      preview: preview
    }

    %{context: context, fake: fake, tmp: tmp}
  end

  defp command(revision \\ "0", key \\ "deposit"),
    do: %{approved: true, expected_revision: revision, idempotency_key: key}

  defp approve(context, cmd \\ command()),
    do: Peer.approve("op_synthetic", "quote_synthetic", cmd, context)

  defp facts(fake, changes \\ %{}) do
    # Private protocol identifiers are minted only in the in-memory fake.
    value =
      Map.merge(
        %{
          state: :confirmed,
          deposit_id: Integer.to_string(1),
          order_id: Integer.to_string(2),
          remaining: "1000000",
          unmatched: "1000000",
          filled: "0",
          withdrawn: "0",
          active_intents: 0
        },
        changes
      )

    Agent.update(fake, &Map.put(&1, :facts, {:ok, value}))
  end

  test "wallet handoff checkpoints uncertainty and resume cannot deposit twice", %{
    context: c,
    fake: fake
  } do
    assert {:requires_user, action, snapshot} = approve(c)
    assert action.action == "create_deposit"
    assert snapshot.peer["state"] == "in_doubt"
    assert snapshot.allowed_actions == ["check_status"]
    assert {:ok, ^snapshot} = approve(c)
    assert {:ok, pending} = Peer.status("op_synthetic", c)
    assert pending.peer["state"] == "in_doubt"
    assert length(Agent.get(fake, & &1.requests)) == 1
    assert {:ok, saved} = Checkpoint.fetch(c.checkpoint, "peer_maker:op_synthetic")

    assert Enum.sort(Map.keys(saved)) ==
             Enum.sort([
               :approval,
               :operation_ref,
               :revision,
               :idempotency_key,
               :snapshot,
               :pending_action_ref
             ])

    assert {:ok, _} = Ramp.encode(snapshot)
  end

  test "lost wallet response remains in doubt and rejects withdrawal", %{context: c, fake: fake} do
    Agent.update(fake, &Map.put(&1, :request, :lost))
    assert {:ok, snapshot} = approve(c)
    assert snapshot.peer["state"] == "in_doubt"

    assert {:error, :invalid_request} =
             Peer.recover("op_synthetic", "recover_peer", command("1", "withdraw"), c)

    assert {:ok, _} = approve(c)
    assert length(Agent.get(fake, & &1.requests)) == 1
  end

  test "approval, expiry, wallet validation and spending policy fail closed", %{
    context: c,
    fake: fake
  } do
    assert {:error, :invalid_request} = approve(c, %{command() | approved: false})
    expired = %{c | now: fn -> DateTime.add(@now, 120) end}
    assert {:error, :invalid_request} = approve(expired)

    denied = %{
      c
      | peer_cashout_policy: %{c.peer_cashout_policy | per_request_max: Decimal.new("0.01")}
    }

    assert {:ok, _} = approve(denied)
    assert Agent.get(fake, & &1.requests) == []
  end

  test "invalid unsigned plan never reaches wallet", %{context: c, fake: fake} do
    Agent.update(fake, &Map.put(&1, :validation, {:error, :invalid_plan}))
    assert {:ok, _} = approve(c)
    assert Agent.get(fake, & &1.requests) == []
    assert Ledger.get_history(c.ledger, {:peer_cashout, :unknown}) == []
  end

  test "reconciles deposit then requires a distinct withdrawal approval", %{
    context: c,
    fake: fake
  } do
    assert {:requires_user, _, _} = approve(c)
    facts(fake)
    assert {:ok, s} = Peer.status("op_synthetic", c)
    assert s.peer["state"] == "processing"

    assert {:error, :invalid_request} =
             Peer.recover("op_synthetic", "recover_peer", command(s.revision, "withdraw"), c)

    cmd = Map.put(command(s.revision, "withdraw"), :amount, "1000000")

    assert {:requires_user, action, pending} =
             Peer.recover("op_synthetic", "recover_peer", cmd, c)

    assert action.action == "withdraw_unmatched"
    assert pending.peer["state"] == "in_doubt"

    assert {:error, :session_conflict, ^pending} =
             Peer.recover("op_synthetic", "recover_peer", cmd, c)

    Agent.update(fake, &Map.put(&1, :facts, {:ok, %{state: :pending}}))
    assert {:ok, uncertain} = Peer.status("op_synthetic", c)
    assert uncertain.allowed_actions == ["check_status"]
    assert Agent.get(fake, & &1.last_pending) == action.action_ref
    facts(fake, %{remaining: "0", unmatched: "0", withdrawn: "1000000"})
    assert {:ok, terminal} = Peer.status("op_synthetic", c)
    assert terminal.terminal
    assert terminal.peer["state"] == "refunded"
    assert length(Agent.get(fake, & &1.requests)) == 2
  end

  test "partial fills and active intents cannot free unavailable funds", %{context: c, fake: fake} do
    assert {:requires_user, _, _} = approve(c)
    facts(fake, %{unmatched: "0", active_intents: 1})
    assert {:ok, s} = Peer.status("op_synthetic", c)
    assert s.allowed_actions == ["check_status"]
    facts(fake, %{remaining: "700000", unmatched: "200000", filled: "300000", active_intents: 1})
    assert {:ok, s} = Peer.status("op_synthetic", c)
    cmd = Map.put(command(s.revision, "withdraw"), :amount, "700000")
    assert {:error, :invalid_request} = Peer.recover("op_synthetic", "recover_peer", cmd, c)
    facts(fake, %{remaining: "0", unmatched: "0", filled: "1000000"})
    assert {:ok, s} = Peer.status("op_synthetic", c)
    assert s.peer["state"] == "completed"
  end

  test "incoherent facts are uncertainty, never completion", %{context: c, fake: fake} do
    assert {:requires_user, _, _} = approve(c)
    facts(fake, %{remaining: "0"})
    assert {:ok, s} = Peer.status("op_synthetic", c)
    assert s.peer["state"] == "in_doubt"
  end

  test "private mapping survives process restart", %{context: c, fake: fake, tmp: tmp} do
    assert {:requires_user, _, _} = approve(c)
    facts(fake)
    assert {:ok, _} = Peer.status("op_synthetic", c)
    assert :ok = stop_supervised(Mapping)

    mapping =
      start_supervised!({Mapping, path: Path.join(tmp, "mapping.dets"), name: :peer_maker_test})

    assert {:ok, %{total: "1000000", deposit_id: _}} = Mapping.fetch(mapping, "op_synthetic")
    assert {:ok, _} = approve(%{c | maker_mapping: mapping})
    assert length(Agent.get(fake, & &1.requests)) == 1
  end

  test "Peer cash-out has a separate policy and budget class", %{context: c, fake: fake} do
    Ledger.record_spend(c.ledger, :unknown, Decimal.new(10_000))
    assert {:requires_user, _, _} = approve(c)
    assert length(Ledger.get_history(c.ledger, {:peer_cashout, :unknown})) == 1
    assert length(Ledger.get_history(c.ledger, :unknown)) == 1
    assert length(Agent.get(fake, & &1.requests)) == 1
  end

  test "generic spending policy cannot replace a dedicated cash-out policy", %{
    context: c,
    fake: fake
  } do
    generic = c |> Map.put(:policy, c.peer_cashout_policy) |> Map.delete(:peer_cashout_policy)
    assert {:ok, _} = approve(generic)
    assert Agent.get(fake, & &1.requests) == []
  end

  test "idempotency key cannot authorize a different operation", %{context: c, fake: fake} do
    assert {:requires_user, _, _} = approve(c)
    other = %{c | preview: %{c.preview | operation_id: "op_other"}}

    assert {:error, :session_conflict, _} =
             Peer.approve("op_other", "quote_synthetic", command(), other)

    assert length(Agent.get(fake, & &1.requests)) == 1
  end

  test "concurrent approval hands off at most once", %{context: c, fake: fake} do
    results =
      1..8 |> Task.async_stream(fn _ -> approve(c) end, max_concurrency: 8) |> Enum.to_list()

    assert Enum.all?(results, fn {:ok, result} -> elem(result, 0) in [:ok, :requires_user] end)
    assert length(Agent.get(fake, & &1.requests)) == 1
  end

  test "lost submission reconciles the existing checkpoint and closes a bounded receipt", %{
    context: c,
    fake: fake
  } do
    Agent.update(fake, &Map.put(&1, :request, :lost))
    assert {:ok, pending} = approve(c)
    facts(fake, %{remaining: "0", unmatched: "0", filled: "1000000"})

    assert {:ok, done} =
             Peer.recover("op_synthetic", "check_status", command(pending.revision), c)

    assert done.terminal
    assert {:ok, ^done} = Peer.status("op_synthetic", c)
    assert {:ok, ^done} = approve(c)

    assert {:ok, %{closed: true, receipt: receipt}} =
             Checkpoint.fetch(c.checkpoint, "peer_maker:op_synthetic")

    assert Enum.sort(Map.keys(receipt)) == [
             :direction,
             :operation_id,
             :revision,
             :state,
             :updated_at
           ]

    assert length(Agent.get(fake, & &1.requests)) == 1
    assert {:error, :session_conflict, ^done} = approve(c, command("0", "changed"))

    assert {:error, :session_conflict, ^done} =
             Peer.recover("op_synthetic", "recover_peer", command(), c)

    assert {:ok, _} = Ramp.encode(done)
  end

  test "authoritative reverted submission closes failed while unknown stays nonterminal", %{
    context: c,
    fake: fake
  } do
    assert {:requires_user, _, _} = approve(c)
    Agent.update(fake, &Map.put(&1, :facts, {:ok, %{state: :reverted}}))
    assert {:ok, done} = Peer.status("op_synthetic", c)
    assert done.terminal and done.peer["state"] == "failed"
    assert done.allowed_actions == []
    assert {:ok, %{closed: true}} = Checkpoint.fetch(c.checkpoint, "peer_maker:op_synthetic")
  end
end

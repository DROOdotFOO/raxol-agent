defmodule Raxol.Payments.Ramp.CompositionTest do
  use ExUnit.Case, async: true
  alias Raxol.Payments.{Checkpoint, Failure, Ramp, SpendingPolicy}
  alias Raxol.Payments.Ramp.Composition

  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  @recipient "0x1111111111111111111111111111111111111111"

  defmodule Wallet do
    def address, do: "0x1111111111111111111111111111111111111111"
  end

  # In-memory leg ports exercise orchestration independently of provider I/O.
  # Their operation records survive the caller, just like the production ports.
  defmodule MemoryPeer do
    def run(operation, _, context) do
      send(self(), {:peer, :approve, operation})
      :ok = Checkpoint.put_new(context.checkpoint, "memory_peer:" <> operation, %{})
      result(context)
    end

    def resume(operation, context) do
      send(self(), {:peer, :resume, operation})
      result(context)
    end

    def status(operation, context) do
      send(self(), {:peer, :status, operation})
      result(context)
    end

    defp result(%{result: :unknown}), do: {:error, :in_doubt}
    defp result(context), do: {:ok, context.snapshot}
  end

  defmodule MemoryRoute do
    def run(params, context) do
      send(self(), {:xochi_execute, params, Map.keys(context)})

      :ok =
        Checkpoint.put_new(context.checkpoint, context.idempotency_key, %{intent_id: "route_1"})

      {:ok, %{intent_id: "route_1", status: "processing"}}
    end
  end

  defmodule InterruptedRoute do
    def run(_, context) do
      :ok =
        Checkpoint.put_new(context.checkpoint, context.idempotency_key, %{intent_id: "route_1"})

      raise "interrupted"
    end
  end

  defmodule MemoryPoll do
    def run(params, _) do
      send(self(), {:xochi_poll, params.intent_id})

      {:ok,
       %{
         intent_id: params.intent_id,
         status: "completed",
         terminal: true,
         settlement_confirmed: true,
         settlement_chain_id: 8453,
         settlement_type: "public"
       }}
    end
  end

  defmodule RefundedPoll do
    def run(_, _), do: {:error, Failure.from({:settlement, :refunded, nil})}
  end

  defmodule UnconfirmedPoll do
    def run(params, _),
      do:
        {:ok,
         %{
           intent_id: params.intent_id,
           status: "completed",
           settlement_confirmed: false,
           settlement_chain_id: 8453,
           settlement_type: "public"
         }}
  end

  defp setup_plan(direction) do
    money = %{
      "atomic" => "500000",
      "asset" => %{
        "kind" => "crypto",
        "chain_id" => "eip155:8453",
        "asset_id" => @usdc,
        "decimals" => 6
      }
    }

    preview = %Ramp.Preview{operation_id: "peer_1", pay: money, receive: money}
    intent = %Ramp.Intent{direction: direction, recipient: @recipient}

    route =
      if direction == "onramp" do
        %{
          from_chain_id: 8453,
          from_token: @usdc,
          to_chain_id: 42_161,
          to_token: @arb,
          settlement: "public",
          recipient_address: @recipient,
          min_to_amount: "400000"
        }
      else
        %{
          from_chain_id: 42_161,
          from_token: @arb,
          to_chain_id: 8453,
          to_token: @usdc,
          settlement: "public",
          recipient_address: @recipient,
          min_to_amount: "500000"
        }
      end

    plan = %{
      direction: direction,
      peer_operation: "peer_1",
      route: route,
      atomic: "500000",
      decimals: 6,
      peer_atomic: "500000",
      recipient: @recipient
    }

    context = %{
      checkpoint: Checkpoint.ETS.new(),
      peer_api: MemoryPeer,
      execute_api: MemoryRoute,
      poll_api: MemoryPoll,
      peer_approval: %{},
      peer_context: %{
        preview: preview,
        intent: intent,
        snapshot: %Ramp.Snapshot{
          operation_id: "peer_1",
          peer: %{"state" => "completed", "payout_state" => "released"}
        }
      },
      xochi_context: %{
        wallet: Wallet,
        policy: SpendingPolicy.unrestricted(),
        on_confirm: fn _, target ->
          send(self(), {:approval, target})
          :approve
        end,
        xochi_config: %{
          base_url: "https://xochi.test",
          req_options: [plug: {Req.Test, __MODULE__}]
        }
      }
    }

    {plan, context}
  end

  test "held or pending Peer cannot even quote the post-route" do
    {plan, c} = setup_plan("onramp")
    assert {:ok, _} = Composition.create("c", plan, c)
    assert {:error, :leg_not_ready} = Composition.advance("c", :xochi, :approve, c)

    held =
      put_in(c.peer_context.snapshot.peer, %{"state" => "completed", "payout_state" => "held"})

    assert {:ok, %{peer: %{state: :pending}}} = Composition.advance("c", :peer, :approve, held)
    assert {:error, :leg_not_ready} = Composition.advance("c", :xochi, :approve, c)
    assert {:ok, _} = Composition.advance("c", :peer, :status, c)
    assert {:ok, _} = Composition.advance("c", :xochi, :approve, c)
    assert_received {:approval, "xochi"}
    assert_received {:xochi_execute, %{amount: "0.500000"}, _}
  end

  test "onramp partial success retries a fresh Xochi quote only and inspects real HTTP payloads" do
    {plan, c} = setup_plan("onramp")
    c = Map.delete(c, :execute_api)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:quote_payload, Jason.decode!(body)})
      Req.Test.json(conn, %{can_solve: false, reason: "insufficient_liquidity"})
    end)

    assert {:ok, _} = Composition.create("c", plan, c)
    assert {:ok, _} = Composition.advance("c", :peer, :approve, c)
    assert_received {:peer, :approve, "peer_1"}

    assert {:ok, %{state: :partial_success, peer: %{state: :completed}, xochi: %{state: :failed}}} =
             Composition.advance("c", :xochi, :approve, c)

    assert_received {:quote_payload, payload}
    assert payload["from_amount"] == "500000"
    assert payload["from_chain_id"] == 8453
    refute Enum.any?(Map.keys(payload), &String.contains?(&1, "peer"))

    assert Map.keys(payload) --
             ~w(deadline gasless wallet from_chain_id to_chain_id from_token to_token from_amount slippage_bps trust_score settlement_preference recipient_address stealth_spending_pub_key stealth_viewing_pub_key swap_kind output_amount max_from_amount) ==
             []

    refute "peer_1" in Map.values(payload)

    assert {:ok, %{peer: %{state: :completed}, xochi: %{attempt: 2}}} =
             Composition.advance("c", :xochi, :approve, c)

    assert_received {:quote_payload, _}
    refute_received {:peer, _, _}
    assert {:ok, record} = Checkpoint.fetch(c.checkpoint, "ramp_composition:c")
    refute Map.has_key?(record, :state)
  end

  test "offramp Peer failure retains prerequisite and recovers only Peer" do
    {plan, c} = setup_plan("offramp")
    assert {:ok, _} = Composition.create("c", plan, c)
    assert {:error, :leg_not_ready} = Composition.advance("c", :peer, :approve, c)
    assert {:ok, _} = Composition.advance("c", :xochi, :approve, c)
    assert {:error, :leg_not_ready} = Composition.advance("c", :peer, :approve, c)

    assert {:ok, %{xochi: %{state: :pending}}} =
             Composition.advance("c", :xochi, :status, %{c | poll_api: UnconfirmedPoll})

    assert {:error, :leg_not_ready} = Composition.advance("c", :peer, :approve, c)
    assert {:ok, %{xochi: %{state: :completed}}} = Composition.advance("c", :xochi, :status, c)
    failed = put_in(c.peer_context[:result], :unknown)

    assert {:ok, %{state: :partial_success, xochi: %{state: :completed}}} =
             Composition.advance("c", :peer, :approve, failed)

    assert {:error, :leg_not_ready} = Composition.advance("c", :xochi, :approve, c)
    assert {:ok, %{state: :completed}} = Composition.advance("c", :peer, :resume, c)
    assert_received {:peer, :resume, "peer_1"}
    assert_received {:xochi_execute, _, _}
    refute_received {:xochi_execute, _, _}
  end

  test "interrupted route reconciles original reference without execution or approval" do
    {plan, c} = setup_plan("offramp")
    assert {:ok, _} = Composition.create("c", plan, c)

    assert {:ok, %{xochi: %{state: :in_doubt}}} =
             Composition.advance("c", :xochi, :approve, %{c | execute_api: InterruptedRoute})

    assert_received {:approval, "xochi"}
    assert {:error, :leg_not_ready} = Composition.advance("c", :xochi, :approve, c)

    assert {:ok, %{xochi: %{operation: "route_1", state: :completed}}} =
             Composition.advance("c", :xochi, :status, c)

    assert_received {:xochi_poll, "route_1"}
    refute_received {:approval, _}
    refute_received {:xochi_execute, _, _}
  end

  test "refunded route allows separate new approval, denial sends nothing" do
    {plan, c} = setup_plan("offramp")
    assert {:ok, _} = Composition.create("c", plan, c)
    assert {:ok, _} = Composition.advance("c", :xochi, :approve, c)

    assert {:ok, %{xochi: %{state: :failed}}} =
             Composition.advance("c", :xochi, :status, %{c | poll_api: RefundedPoll})

    assert_received {:xochi_execute, _, _}
    denied = put_in(c.xochi_context.on_confirm, fn _, _ -> :deny end)
    assert {:ok, %{xochi: %{state: :failed}}} = Composition.advance("c", :xochi, :approve, denied)
    refute_received {:xochi_execute, _, _}
    assert {:ok, %{xochi: %{attempt: 3}}} = Composition.advance("c", :xochi, :approve, c)
    assert_received {:xochi_execute, _, _}
  end

  test "reject wrong settlement, underfunding, mismatched wallet, and extra plan data" do
    {plan, c} = setup_plan("offramp")

    for invalid <- [
          put_in(plan.route.settlement, "stealth"),
          put_in(plan.route.min_to_amount, "499999"),
          %{plan | recipient: "other"},
          %{plan | atomic: "0.5"},
          Map.put(plan, :extra, "unsupported")
        ] do
      assert {:error, :invalid_plan_or_exists} = Composition.create("c", invalid, c)
    end

    assert {:ok, _} = Composition.create("c", plan, c)
    changed = put_in(c.peer_context.preview.pay["atomic"], "600000")
    assert {:error, :leg_not_ready} = Composition.advance("c", :xochi, :approve, changed)
  end

  test "confirmed failed Peer can use a fresh reference without repeating prerequisite" do
    {plan, c} = setup_plan("offramp")
    assert {:ok, _} = Composition.create("c", plan, c)
    assert {:ok, _} = Composition.advance("c", :xochi, :approve, c)
    assert {:ok, _} = Composition.advance("c", :xochi, :status, c)

    failed =
      put_in(c.peer_context.snapshot, %Ramp.Snapshot{
        operation_id: "peer_1",
        terminal: true,
        peer: %{"state" => "failed"}
      })

    assert {:ok, %{state: :partial_success}} = Composition.advance("c", :peer, :approve, failed)
    fresh = put_in(c.peer_context.preview.operation_id, "peer_2")
    fresh = put_in(fresh.peer_context.snapshot.operation_id, "peer_2")

    assert {:ok, %{peer: %{state: :ready}, peer_history: [%{operation: "peer_1"}]}} =
             Composition.retry_peer("c", "peer_2", fresh)

    assert {:ok, %{state: :completed}} = Composition.advance("c", :peer, :approve, fresh)
    assert_received {:xochi_execute, _, _}
    refute_received {:xochi_execute, _, _}
    assert_received {:peer, :approve, "peer_2"}
  end
end

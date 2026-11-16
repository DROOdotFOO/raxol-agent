defmodule Raxol.Payments.Ramp.Peer.Maker do
  @moduledoc """
  Approval-gated Peer maker execution and status-only submission recovery.

  Requires a checkpoint store, a supervised private `:maker_mapping` server,
  trusted `:maker_io` and `:maker_wallet` boundaries, spending policy and ledger.
  The caller supplies the validated `:preview` and `:intent` for initial approval.
  Public operation references must be scoped to the authenticated wallet by the
  host; the I/O and wallet boundaries independently verify that binding.

  Before any I/O the operation is reserved in the checkpoint. Once wallet
  handoff starts, only reconciliation can advance it. A crash, exception or lost
  response cannot authorize another deposit or withdrawal. Failed preparation
  also conservatively requires reconciliation. Withdrawal uses `recover_peer`
  with a separately reviewed `:amount` and explicit `:approved` command flag.
  No runtime wallet keys or signatures are accepted by this API.
  """
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer.Mapping

  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  def approve(operation, quote, command, context) do
    safely(fn ->
      locked(operation, context, fn -> approve_locked(operation, quote, command, context) end)
    end)
  end

  defp approve_locked(operation, quote, command, context) do
    case Checkpoint.fetch(context.checkpoint, key(operation)) do
      {:ok, record} -> {:ok, record.snapshot}
      :error -> begin_deposit(operation, quote, command, context)
    end
  end

  def status(operation, context) do
    safely(fn -> locked(operation, context, fn -> reconcile(operation, context) end) end)
  end

  def recover(operation, "check_status", _, context), do: status(operation, context)

  def recover(operation, "recover_peer", command, context) do
    safely(fn -> locked(operation, context, fn -> withdraw(operation, command, context) end) end)
  end

  def recover(_, _, _, _), do: {:error, :invalid_request}

  defp withdraw(operation, command, context) do
    with {:ok, record} <- Checkpoint.fetch(context.checkpoint, key(operation)),
         true <- record.snapshot.peer["state"] == "processing",
         true <- "recover_peer" in record.snapshot.allowed_actions,
         :ok <- command_valid(command, record.revision),
         true <- command.idempotency_key != record.idempotency_key,
         {:ok, mapping} <- Mapping.fetch(context.maker_mapping, operation),
         {:ok, facts} <- read_facts(operation, record, context),
         true <- valid_facts?(facts, mapping),
         amount when is_binary(amount) <- command[:amount],
         true <- positive?(amount),
         true <- withdrawable?(amount, facts) do
      handoff(operation, :withdraw_unmatched, %{amount: amount}, record, command, context)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp begin_deposit(operation, quote, command, context) do
    with %Ramp.Preview{} = preview <- context[:preview],
         %Ramp.Intent{direction: "offramp", route: nil} = intent <- context[:intent],
         {:ok, _} <- Ramp.decode(Ramp.to_wire(preview)),
         {:ok, _} <- Ramp.decode(Ramp.to_wire(intent)),
         true <- preview.operation_id == operation and preview.quote_id == quote,
         true <- preview.leg_order == ["peer"],
         true <- base_usdc?(preview.pay["asset"]) and preview.pay["asset"] == intent.crypto,
         true <- positive?(preview.pay["atomic"]),
         {:ok, expiry, 0} <- DateTime.from_iso8601(preview.expires_at),
         true <- DateTime.compare(expiry, now(context)) == :gt,
         :ok <- command_valid(command, "0") do
      record = record(operation, "0", command.idempotency_key, nil, context)

      with :ok <- Checkpoint.put_new(context.checkpoint, key(operation), record),
           :ok <- Mapping.put(context.maker_mapping, operation, %{total: preview.pay["atomic"]}) do
        terms = %{amount: preview.pay["atomic"], preview: preview, intent: intent}
        handoff(operation, :create_deposit, terms, record, command, context)
      else
        _ -> {:error, :session_conflict}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp handoff(operation, action, terms, previous, command, context) do
    command_key = "peer_maker_command:" <> Checkpoint.derive_key([command.idempotency_key])

    case Checkpoint.put_new(context.checkpoint, command_key, previous) do
      :ok -> handoff_once(operation, action, terms, previous, command, context)
      _ -> {:error, :session_conflict}
    end
  end

  defp handoff_once(operation, action, terms, previous, command, context) do
    revision = to_string(String.to_integer(previous.revision) + 1)
    pending = "action_" <> Checkpoint.derive_key([operation, revision, action])
    reserved = record(operation, revision, command.idempotency_key, pending, context)
    # Persist uncertainty before preparing a plan, reserving spend or calling the wallet.
    :ok = Checkpoint.put(context.checkpoint, key(operation), reserved)

    result =
      uncertain(reserved, fn ->
        with {:ok, mapping} <- Mapping.fetch(context.maker_mapping, operation),
             {:ok, plan} <- io(context, :prepare, [operation, action, terms, mapping]),
             :ok <- wallet(context, :validate, [plan, Map.put(terms, :action, action)]),
             {:ok, _} <- authorize(terms.amount, context),
             :ok <- wallet(context, :request, [operation, pending, plan]) do
          public = %{action_ref: pending, kind: "wallet_approval", action: Atom.to_string(action)}
          {:requires_user, public, reserved.snapshot}
        else
          _ -> {:ok, reserved.snapshot}
        end
      end)

    result
  end

  defp authorize(amount, context) do
    # Require the shared policy and atomic session/lifetime accounting in all environments.
    if not is_nil(context[:policy]) and not is_nil(context[:ledger]) do
      human = Decimal.div(Decimal.new(amount), Decimal.new(1_000_000))

      SpendGate.authorize(Map.put(context, :require_policy, true), human,
        asset: {:token, 8453, @usdc},
        target: {:domain, "peer.xyz"}
      )
    else
      {:error, :policy_required}
    end
  end

  defp reconcile(operation, context) do
    case Checkpoint.fetch(context.checkpoint, key(operation)) do
      {:ok, previous} ->
        if previous.snapshot.terminal do
          {:ok, previous.snapshot}
        else
          revision = to_string(String.to_integer(previous.revision) + 1)

          reserved =
            record(
              operation,
              revision,
              previous.idempotency_key,
              previous.pending_action_ref,
              context
            )

          :ok = Checkpoint.put(context.checkpoint, key(operation), reserved)
          reconcile_facts(operation, reserved, context)
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp read_facts(operation, record, context) do
    # Status is an external boundary too, including the read preceding withdrawal.
    :ok = Checkpoint.put(context.checkpoint, key(operation), record)

    with {:ok, mapping} <- Mapping.fetch(context.maker_mapping, operation) do
      io(context, :reconcile, [
        operation,
        Map.put(mapping, :pending_action_ref, record.pending_action_ref)
      ])
    end
  end

  defp reconcile_facts(operation, record, context) do
    uncertain(record, fn ->
      with {:ok, mapping} <- Mapping.fetch(context.maker_mapping, operation),
           {:ok, facts} <- read_facts(operation, record, context),
           true <- valid_facts?(facts, mapping),
           :ok <-
             Mapping.put(
               context.maker_mapping,
               operation,
               Map.merge(mapping, Map.take(facts, [:deposit_id, :order_id]))
             ) do
        {state, actions} = normalized(facts)
        snapshot = snapshot(operation, record.revision, state, actions, context)
        updated = %{record | snapshot: snapshot, pending_action_ref: nil}
        :ok = Checkpoint.put(context.checkpoint, key(operation), updated)
        {:ok, snapshot}
      else
        _ -> {:ok, record.snapshot}
      end
    end)
  end

  defp valid_facts?(%{state: :confirmed} = facts, mapping) do
    amounts = Enum.map([:remaining, :unmatched, :filled, :withdrawn], &Map.get(facts, &1))

    if Enum.all?(amounts, &(Ramp.atomic?(&1) and byte_size(&1) <= 78)) and
         valid_identifiers?(facts, mapping) do
      [remaining, unmatched, filled, withdrawn] = Enum.map(amounts, &String.to_integer/1)

      remaining >= unmatched and
        remaining + filled + withdrawn == String.to_integer(mapping.total) and
        (remaining > 0 or facts.active_intents == 0)
    else
      false
    end
  end

  defp valid_facts?(_, _), do: false

  defp valid_identifiers?(facts, mapping) do
    is_integer(facts[:active_intents]) and facts.active_intents >= 0 and
      is_binary(facts[:deposit_id]) and
      (is_nil(mapping[:deposit_id]) or mapping.deposit_id == facts.deposit_id)
  end

  defp withdrawable?(amount, facts) do
    String.to_integer(amount) <= String.to_integer(facts.unmatched) and
      (amount != facts.remaining or facts.active_intents == 0)
  end

  defp normalized(%{remaining: "0", withdrawn: "0"}), do: {"completed", []}
  defp normalized(%{remaining: "0"}), do: {"refunded", []}
  defp normalized(%{unmatched: "0"}), do: {"processing", ["check_status"]}
  defp normalized(_), do: {"processing", ["check_status", "recover_peer"]}

  defp record(operation, revision, idempotency, pending, context) do
    %{
      operation_ref: operation,
      revision: revision,
      idempotency_key: idempotency,
      pending_action_ref: pending,
      snapshot: snapshot(operation, revision, "in_doubt", ["check_status"], context)
    }
  end

  defp snapshot(operation, revision, state, actions, context) do
    {:ok, snapshot} =
      Ramp.decode(%{
        "contract_version" => "ramp/1",
        "kind" => "snapshot",
        "operation_id" => operation,
        "revision" => revision,
        "direction" => "offramp",
        "leg_order" => ["peer"],
        "peer" => %{
          "name" => "peer",
          "state" => state,
          "recoverable" => state not in ["completed", "refunded"]
        },
        "allowed_actions" => actions,
        "updated_at" => DateTime.to_iso8601(now(context)),
        "terminal" => state in ["completed", "refunded"]
      })

    snapshot
  end

  defp command_valid(
         %{approved: true, expected_revision: revision, idempotency_key: key},
         revision
       )
       when is_binary(key) and byte_size(key) in 1..128, do: :ok

  defp command_valid(_, _), do: {:error, :approval_required}

  defp base_usdc?(a),
    do:
      a["chain_id"] == "eip155:8453" and a["decimals"] == 6 and Ramp.Coherence.address(a) == @usdc

  defp positive?(v),
    do:
      Ramp.atomic?(v) and byte_size(v) <= 78 and String.to_integer(v) > 0 and
        String.to_integer(v) < Integer.pow(2, 256)

  defp key(operation), do: "peer_maker:" <> operation
  defp now(context), do: Map.get(context, :now, &DateTime.utc_now/0).()
  defp io(%{maker_io: {module, handle}}, method, args), do: apply(module, method, [handle | args])

  defp wallet(%{maker_wallet: {module, handle}}, method, args),
    do: apply(module, method, [handle | args])

  defp locked(operation, context, fun) do
    true = not is_nil(context[:checkpoint]) and not is_nil(context[:maker_mapping])
    :global.trans({{__MODULE__, context.checkpoint, operation}, self()}, fun)
  end

  defp uncertain(record, fun) do
    fun.()
  rescue
    _ -> {:ok, record.snapshot}
  catch
    _, _ -> {:ok, record.snapshot}
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end
end

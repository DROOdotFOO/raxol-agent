defmodule Raxol.Payments.Ramp.Composition do
  @moduledoc """
  Non-atomic composition with separate trusted contexts and checkpoints.

  Hosts bind the plan and contexts to one authenticated wallet. `advance/4`
  operates one leg only; status never implicitly starts the following leg.
  Route parameters use the existing Xochi action schema. Peer parameters and
  context are never forwarded to Xochi. Stores must be durable and principal
  scoped, with shared locking on multi-node deployments.
  """
  alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
  alias Raxol.Payments.{Assets, Checkpoint, Failure, Ramp, Ramps}
  alias Raxol.Payments.Ramp.Coherence

  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @fields ~w(from_chain_id to_chain_id from_token to_token settlement recipient_address recipient_meta_address min_to_amount slippage_bps)a

  def create(id, plan, context) do
    lock(id, context, fn ->
      with true <- valid?(plan) and bound?(plan, context),
           :ok <-
             Checkpoint.put_new(context.checkpoint, key(id), %{
               plan: plan,
               peer: %{state: :ready, operation: plan.peer_operation, receipt: nil},
               xochi: %{state: :ready, operation: nil, receipt: nil, attempt: 0}
             }) do
        status(id, context)
      else
        _ -> {:error, :invalid_plan_or_exists}
      end
    end)
  end

  @doc "Replace a confirmed failed or refunded Peer leg with a fresh preview/reference."
  def retry_peer(id, operation, context) do
    lock(id, context, fn ->
      with {:ok, record} <- Checkpoint.fetch(context.checkpoint, key(id)),
           true <-
             peer_state(record) in [:failed, :refunded] and record.peer.receipt.terminal == true,
           true <- operation != record.peer.operation,
           plan = %{record.plan | peer_operation: operation},
           true <- bound?(plan, context),
           updated =
             %{record | plan: plan, peer: %{state: :ready, operation: operation, receipt: nil}}
             |> Map.update(:peer_history, [record.peer], &[record.peer | &1]),
           :ok <- Checkpoint.put(context.checkpoint, key(id), updated) do
        {:ok, view(updated)}
      else
        _ -> {:error, :reconcile_required}
      end
    end)
  end

  def status(id, context) do
    with {:ok, record} <- Checkpoint.fetch(context.checkpoint, key(id)), do: {:ok, view(record)}
  end

  def advance(id, leg, action, context) when leg in [:peer, :xochi] do
    lock(id, context, fn -> advance_locked(id, leg, action, context) end)
  end

  defp advance_locked(id, leg, action, context) do
    with {:ok, record} <- Checkpoint.fetch(context.checkpoint, key(id)),
         true <- eligible?(record, leg) and bound?(record.plan, context),
         true <- action in [:approve, :resume, :status],
         true <- leg_state(record, leg) not in [:completed, :refunded, :partial_success],
         true <- action == :approve or record[leg].state != :ready,
         true <-
           action != :approve or record[leg].state == :ready or
             (leg == :xochi and record.xochi.state == :failed) do
      record =
        if leg == :xochi and action == :approve,
          do: next_route_attempt(record),
          else: record

      :ok = Checkpoint.put(context.checkpoint, key(id), put_in(record[leg].state, :in_doubt))
      result = safe(fn -> dispatch(id, record, leg, action, context) end)
      updated = apply_result(record, leg, result)
      updated = execution_failure(id, updated, leg, action, result, context)
      with :ok <- Checkpoint.put(context.checkpoint, key(id), updated), do: {:ok, view(updated)}
    else
      _ -> {:error, :leg_not_ready}
    end
  end

  defp dispatch(_, record, :peer, action, context) do
    api = Map.get(context, :peer_api, Ramps)
    peer = Map.put(context.peer_context, :checkpoint, context.checkpoint)

    case action do
      :approve -> api.run(record.peer.operation, context.peer_approval, peer)
      :resume -> api.resume(record.peer.operation, peer)
      :status -> api.status(record.peer.operation, peer)
    end
  end

  defp dispatch(id, record, :xochi, action, context) do
    clean =
      context.xochi_context
      |> Map.take([
        :wallet,
        :xochi_config,
        :policy,
        :ledger,
        :agent_id,
        :on_confirm,
        :clock,
        :price_fn
      ])
      |> Map.merge(%{
        checkpoint: context.checkpoint,
        require_checkpoint: true,
        require_policy: true,
        idempotency_key: route_key(id, record.xochi.attempt)
      })

    if action == :approve,
      do: execute_route(record, clean, context),
      else: poll_route(record, clean, context)
  end

  defp execute_route(record, clean, context) do
    confirm = Map.fetch!(clean, :on_confirm)
    clean = Map.put(clean, :on_confirm, fn _, _ -> :approve end)
    api = Map.get(context, :execute_api, ExecuteXochiIntent)
    amount = Decimal.new(1, String.to_integer(record.plan.atomic), -record.plan.decimals)

    params =
      Map.take(record.plan.route, @fields)
      |> Map.put(:amount, Decimal.to_string(amount, :normal))

    case confirm.(amount, "xochi") do
      :approve -> api.run(params, clean)
      _ -> {:error, :approval_required}
    end
  end

  defp poll_route(record, clean, context) do
    operation = record.xochi.operation || recover_reference(clean)

    if operation do
      api = Map.get(context, :poll_api, PollXochiStatus)

      case api.run(%{intent_id: operation, timeout_ms: 0}, clean) do
        {:error, %Failure{reason: reason}} when reason in [:refunded, :expired] ->
          {:terminal_failure, operation, reason}

        other ->
          other
      end
    else
      {:error, :reconciliation_required}
    end
  end

  defp apply_result(record, :peer, {:requires_user, action, snapshot}) do
    updated = apply_result(record, :peer, {:ok, snapshot})
    put_in(updated.peer, Map.put(updated.peer, :action, Map.take(action, [:action_ref, :code])))
  end

  defp apply_result(record, :peer, {:ok, snapshot}) do
    %{
      record
      | peer: %{
          Map.delete(record.peer, :action)
          | state: classify_peer(snapshot, record.plan.direction),
            receipt: snapshot
        }
    }
  end

  defp apply_result(record, :xochi, {:ok, %{intent_id: operation} = receipt}) do
    confirmed = receipt[:settlement_confirmed] == true and receipt[:legs_withheld] != true

    spendable =
      record.plan.direction == "onramp" or
        (receipt[:settlement_type] == "public" and receipt[:settlement_chain_id] == 8453)

    completed = confirmed and spendable

    state =
      cond do
        completed -> :completed
        receipt[:reconciling] == true -> :in_doubt
        true -> :pending
      end

    %{
      record
      | xochi: %{
          record.xochi
          | operation: operation,
            state: state,
            receipt:
              Map.take(receipt, [
                :intent_id,
                :status,
                :settlement_confirmed,
                :settlement_chain_id,
                :settlement_type
              ])
        }
    }
  end

  defp apply_result(record, :xochi, {:terminal_failure, operation, reason}),
    do: %{
      record
      | xochi: %{
          record.xochi
          | state: :failed,
            operation: operation,
            receipt: %{intent_id: operation, failure_code: reason}
        }
    }

  defp apply_result(record, leg, _), do: put_in(record[leg].state, :in_doubt)

  defp classify_peer(%{terminal: true, peer: %{"state" => "refunded"}}, _), do: :refunded

  defp classify_peer(%{terminal: true, peer: %{"partial_result" => split}}, _) when is_map(split),
    do: :partial_success

  defp classify_peer(%{peer: %{"state" => "completed"}}, "offramp"), do: :completed

  defp classify_peer(%{peer: %{"state" => "completed", "payout_state" => "released"}}, _),
    do: :completed

  defp classify_peer(%{peer: %{"state" => "failed"}}, _), do: :failed
  defp classify_peer(%{peer: %{"state" => "in_doubt"}}, _), do: :in_doubt
  defp classify_peer(_, _), do: :pending

  defp eligible?(%{plan: %{direction: "onramp"}}, :peer), do: true
  defp eligible?(%{plan: %{direction: "offramp"}}, :xochi), do: true
  defp eligible?(record, :peer), do: record.xochi.state == :completed
  defp eligible?(record, :xochi), do: record.peer.state == :completed

  defp valid?(plan) do
    Enum.sort(Map.keys(plan)) ==
      Enum.sort([
        :direction,
        :peer_operation,
        :route,
        :atomic,
        :decimals,
        :recipient,
        :peer_atomic
      ]) and
      Assets.fetch_decimals(plan.route.from_chain_id, plan.route.from_token) ==
        {:ok, plan.decimals} and
      plan.direction in ["onramp", "offramp"] and is_binary(plan.peer_operation) and
      is_integer(plan.decimals) and plan.decimals in 0..36 and positive?(plan.atomic) and
      Enum.all?(Map.keys(plan.route), &(&1 in @fields)) and boundary?(plan)
  rescue
    _ -> false
  end

  defp boundary?(%{direction: "offramp"} = plan),
    do:
      plan.route[:to_chain_id] == 8453 and plan.route[:to_token] == @usdc and
        plan.route[:settlement] == "public" and plan.route[:recipient_address] == plan.recipient and
        positive?(plan.route[:min_to_amount]) and positive?(plan.peer_atomic) and
        String.to_integer(plan.route.min_to_amount) >= String.to_integer(plan.peer_atomic)

  defp boundary?(plan),
    do:
      plan.route[:from_chain_id] == 8453 and plan.route[:from_token] == @usdc and
        plan.decimals == 6

  defp positive?(value), do: is_binary(value) and Regex.match?(~r/\A[1-9][0-9]*\z/, value)

  defp peer_state(%{peer: %{receipt: %{terminal: true, peer: %{"state" => "refunded"}}}}),
    do: :refunded

  defp peer_state(record), do: record.peer.state

  defp leg_state(record, :peer), do: peer_state(record)
  defp leg_state(record, :xochi), do: record.xochi.state

  defp view(record) do
    peer = %{record.peer | state: peer_state(record)}
    states = [peer.state, record.xochi.state]

    state =
      cond do
        Enum.all?(states, &(&1 == :completed)) ->
          :completed

        :partial_success in states or
            (:completed in states and Enum.any?(states, &(&1 in [:failed, :in_doubt, :refunded]))) ->
          :partial_success

        :failed in states or :refunded in states ->
          :failed

        :in_doubt in states ->
          :in_doubt

        true ->
          :pending
      end

    %{
      peer: peer,
      xochi: record.xochi,
      state: state,
      peer_history: Map.get(record, :peer_history, []),
      xochi_history: Map.get(record, :xochi_history, [])
    }
  end

  defp bound?(plan, context) do
    preview = context.peer_context.preview
    intent = context.peer_context.intent
    money = if plan.direction == "offramp", do: preview.pay, else: preview.receive
    wallet = context.xochi_context.wallet

    match?(%Ramp.Preview{}, preview) and match?(%Ramp.Intent{}, intent) and
      preview.operation_id == plan.peer_operation and intent.direction == plan.direction and
      intent.recipient == plan.recipient and
      String.downcase(wallet.address()) == String.downcase(plan.recipient) and
      settlement_bound?(plan, money)
  rescue
    _ -> false
  end

  defp settlement_bound?(plan, money) do
    money["atomic"] == plan.peer_atomic and
      money["asset"]["chain_id"] == "eip155:8453" and money["asset"]["decimals"] == 6 and
      Coherence.address(money["asset"]) == @usdc and
      (plan.direction == "offramp" or
         String.to_integer(plan.atomic) <= String.to_integer(plan.peer_atomic))
  end

  defp recover_reference(clean) do
    case Checkpoint.fetch(clean.checkpoint, clean.idempotency_key) do
      {:ok, %{intent_id: operation}} -> operation
      _ -> nil
    end
  end

  defp execution_failure(
         id,
         record,
         :xochi,
         :approve,
         {:error, %Failure{reason: reason}},
         context
       ) do
    # The existing execute action writes before submission and clears only
    # proven local/clean rejection failures. An absent record proves retry safe.
    case Checkpoint.fetch(context.checkpoint, route_key(id, record.xochi.attempt)) do
      :error ->
        %{record | xochi: %{record.xochi | state: :failed, receipt: %{failure_code: reason}}}

      _ ->
        record
    end
  end

  defp execution_failure(_, record, :xochi, :approve, {:error, :approval_required}, _),
    do: put_in(record.xochi.state, :failed)

  defp execution_failure(_, record, :peer, :approve, {:error, reason}, context)
       when reason in [
              :invalid_request,
              :approval_required,
              :setup_required,
              :capability_changed,
              :session_conflict
            ] do
    operation = record.peer.operation

    with :error <- Checkpoint.fetch(context.checkpoint, "peer_onramp:" <> operation),
         :error <- Checkpoint.fetch(context.checkpoint, "peer_maker:" <> operation) do
      put_in(record.peer.state, :ready)
    else
      _ -> record
    end
  end

  defp execution_failure(_, record, _, _, _, _), do: record

  defp next_route_attempt(record) do
    updated = %{
      record
      | xochi: %{record.xochi | attempt: record.xochi.attempt + 1, operation: nil}
    }

    if record.xochi.attempt > 0,
      do: Map.update(updated, :xochi_history, [record.xochi], &[record.xochi | &1]),
      else: updated
  end

  defp route_key(id, attempt), do: Checkpoint.derive_key(["ramp-route", id, attempt])

  defp key(id), do: "ramp_composition:" <> id

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :in_doubt}
  catch
    _, _ -> {:error, :in_doubt}
  end

  defp lock(id, %{checkpoint: {_, _}} = context, fun),
    do: :global.trans({{__MODULE__, context.checkpoint, id}, self()}, fun)

  defp lock(_, _, _), do: {:error, :checkpoint_required}
end

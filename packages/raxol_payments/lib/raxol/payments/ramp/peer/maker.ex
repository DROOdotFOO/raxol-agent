defmodule Raxol.Payments.Ramp.Peer.Maker do
  @moduledoc """
  Approval-gated Peer maker execution and status-only submission recovery.

  Requires a checkpoint store, supervised private mapping/indexer resources,
  a dedicated `:peer_cashout_policy`, ledger and user-wallet approval context.
  Concrete maker I/O and wallet implementations are defaults; tests may inject
  `:maker_io` and `:maker_wallet` behaviours.
  The caller supplies the validated `:preview` and `:intent` for initial approval.
  Public operation references must be scoped to the authenticated wallet by the
  host; the I/O and wallet boundaries independently verify that binding.

  Before any I/O the operation is reserved in the checkpoint. Once wallet
  handoff starts, only reconciliation can advance it. A crash, exception or lost
  response cannot authorize another deposit or withdrawal. Failed preparation
  can return to the previous state when submission was ruled out. A deposit retry
  can use the original unexpired reviewed preview. A new preview requires its
  `:quote_id` in the separately approved `recover_peer` command.
  Withdrawal uses `recover_peer`
  with a separately reviewed `:amount` and explicit `:approved` command flag.
  No runtime wallet keys or signatures are accepted by this API.
  """
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer.{LiveIO, Mapping}
  alias Raxol.Payments.Ramp.Recovery

  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  def approve(operation, quote, command, context) do
    context = dependencies(context)

    safely(fn ->
      locked(operation, context, fn -> approve_locked(operation, quote, command, context) end)
    end)
  end

  defp approve_locked(operation, quote, command, context) do
    case Checkpoint.fetch(context.checkpoint, key(operation)) do
      {:ok, record} ->
        if record[:approval] == approval(quote, command),
          do: {:ok, record.snapshot},
          else: Recovery.conflict(record)

      :error ->
        begin_deposit(operation, quote, command, context)
    end
  end

  def status(operation, context) do
    context = dependencies(context)
    safely(fn -> locked(operation, context, fn -> reconcile(operation, context) end) end)
  end

  def recover(operation, "check_status", _, context), do: status(operation, context)

  def recover(operation, "recover_peer", command, context) do
    context = dependencies(context)

    safely(fn ->
      locked(operation, context, fn -> recover_locked(operation, command, context) end)
    end)
  end

  def recover(_, _, _, _), do: {:error, :invalid_request}

  defp recover_locked(operation, command, context) do
    with {:ok, record} <- Checkpoint.fetch(context.checkpoint, key(operation)),
         true <- is_map(command) and command[:expected_revision] == record.revision do
      recover_current(operation, command, context)
    else
      false ->
        {:ok, record} = Checkpoint.fetch(context.checkpoint, key(operation))
        Recovery.conflict(record)

      _ ->
        {:error, :operation_not_found}
    end
  end

  defp recover_current(operation, command, context) do
    case Checkpoint.fetch(context.checkpoint, key(operation)) do
      {:ok, %{snapshot: %{peer: %{"state" => "action_required"}}} = previous} ->
        with :ok <- command_valid(command, previous.revision),
             true <- command.idempotency_key != previous.idempotency_key,
             {:ok, preview, intent} <- deposit_review(operation, context),
             review <- reviewed_terms(preview, intent),
             true <- reviewed?(previous[:reviewed_terms], review, command),
             {:ok, %{total: amount}} <- Mapping.fetch_maker(context, operation),
             true <- preview.pay["atomic"] == amount do
          terms = %{amount: amount, preview: preview, intent: intent}

          handoff(
            operation,
            :create_deposit,
            terms,
            Map.put(previous, :reviewed_terms, review),
            command,
            context
          )
        else
          _ -> {:error, :invalid_request}
        end

      _ ->
        withdraw(operation, command, context)
    end
  end

  defp withdraw(operation, command, context) do
    with {:ok, record} <- Checkpoint.fetch(context.checkpoint, key(operation)),
         true <- record.snapshot.peer["state"] == "processing",
         true <- "recover_peer" in record.snapshot.allowed_actions,
         :ok <- command_valid(command, record.revision),
         true <- command.idempotency_key != record.idempotency_key,
         {:ok, mapping} <- Mapping.fetch_maker(context, operation),
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
    with {:ok, preview, intent} <- deposit_review(operation, context),
         true <- preview.quote_id == quote,
         :ok <- command_valid(command, "0"),
         :ok <- Recovery.reserve(context, operation, "offramp") do
      record =
        Map.merge(record(operation, "0", command.idempotency_key, nil, context), %{
          snapshot: ready_to_deposit(operation, "0", context),
          approval: approval(quote, command),
          reviewed_terms: reviewed_terms(preview, intent)
        })

      with :ok <- Mapping.insert_maker(context, operation, %{total: preview.pay["atomic"]}),
           :ok <- Checkpoint.put_new(context.checkpoint, key(operation), record) do
        terms = %{amount: preview.pay["atomic"], preview: preview, intent: intent}
        handoff(operation, :create_deposit, terms, record, command, context)
      else
        _ -> {:error, :session_conflict}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp deposit_review(operation, context) do
    with %Ramp.Preview{} = preview <- context[:preview],
         %Ramp.Intent{direction: "offramp", route: nil} = intent <- context[:intent],
         {:ok, _} <- Ramp.decode(Ramp.to_wire(preview)),
         {:ok, _} <- Ramp.decode(Ramp.to_wire(intent)),
         true <- preview.operation_id == operation and preview.leg_order == ["peer"],
         true <- base_usdc?(preview.pay["asset"]) and preview.pay["asset"] == intent.crypto,
         true <- positive?(preview.pay["atomic"]),
         {:ok, expiry, 0} <- DateTime.from_iso8601(preview.expires_at),
         true <- DateTime.compare(expiry, now(context)) == :gt do
      {:ok, preview, intent}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp handoff(operation, action, terms, previous, command, context) do
    case Recovery.claim(context, operation, action, command) do
      :new -> handoff_once(operation, action, terms, previous, command, context)
      :replayed -> {:ok, previous.snapshot}
      :conflict -> Recovery.conflict(previous)
    end
  end

  defp handoff_once(operation, action, terms, previous, command, context) do
    revision = to_string(String.to_integer(previous.revision) + 1)
    owner = String.downcase(context.user)
    pending = "action_" <> Checkpoint.derive_key([owner, operation, revision, action])

    reserved =
      Map.merge(previous, record(operation, revision, command.idempotency_key, pending, context))

    # Persist uncertainty before preparing a plan, reserving spend or calling the wallet.
    :ok = Checkpoint.put(context.checkpoint, key(operation), reserved)

    uncertain(reserved, fn ->
      with {:ok, mapping} <- Mapping.fetch_maker(context, operation),
           {:ok, requested} <- mark_requested(operation, action, pending, mapping, context) do
        prepare_handoff(operation, action, terms, requested, reserved, context)
      else
        _ -> {:ok, reserved.snapshot}
      end
    end)
  end

  defp mark_requested(operation, action, pending, mapping, context) do
    requested =
      Map.merge(mapping, %{
        pending_action_ref: pending,
        pending_kind: {:requested, action},
        pending_tx_hash: nil,
        pending_resolved: false,
        pending_failed: false
      })

    with :ok <- Mapping.put_maker(context, operation, requested), do: {:ok, requested}
  end

  defp prepare_handoff(operation, action, terms, mapping, record, context) do
    pending = record.pending_action_ref

    with {:ok, plan} <- io(context, :prepare, [operation, action, terms, mapping]),
         :ok <- wallet(context, :validate, [plan, Map.put(terms, :action, action)]),
         :ok <- authorize(action, terms.amount, pending, context) do
      case wallet(context, :request, [operation, pending, plan]) do
        :ok ->
          public = %{
            action_ref: pending,
            kind: "wallet_approval",
            action: Atom.to_string(Map.get(plan, :action, action))
          }

          {:requires_user, public, record.snapshot}

        {:error, _} ->
          reconcile_facts(operation, record, context)
      end
    else
      _ ->
        :ok =
          Mapping.put_maker(context, operation, %{mapping | pending_resolved: true})

        reconciliation_result(operation, record, %{state: :unsubmitted}, context)
    end
  end

  defp authorize(:withdraw_unmatched, _, _, _), do: :ok

  defp authorize(:create_deposit, amount, pending, context) do
    # Require the dedicated cash-out policy and atomic session/lifetime accounting in all environments.
    if not is_nil(context[:peer_cashout_policy]) and not is_nil(context[:ledger]) do
      human = Decimal.div(Decimal.new(amount), Decimal.new(1_000_000))

      with {:ok, spend} <-
             SpendGate.authorize(cashout_budget(context), human,
               asset: {:token, 8453, @usdc},
               target: {:domain, "peer.xyz"}
             ) do
        SpendGate.tag_reservation(class_context(context), pending, spend)
      end
    else
      {:error, :policy_required}
    end
  end

  defp cashout_budget(context) do
    context
    |> class_context()
    |> Map.put(:require_policy, true)
    |> Map.put(:policy, context.peer_cashout_policy)
  end

  defp class_context(context),
    do: Map.put(context, :agent_id, {:peer_cashout, Map.get(context, :agent_id, :unknown)})

  defp reconcile(operation, context) do
    case Checkpoint.fetch(context.checkpoint, key(operation)) do
      {:ok, %{snapshot: %{terminal: true} = snapshot}} ->
        {:ok, snapshot}

      {:ok, previous} ->
        current = status_record(operation, previous, context)
        :ok = Checkpoint.put(context.checkpoint, key(operation), current)
        reconcile_facts(operation, current, context)

      _ ->
        {:error, :invalid_request}
    end
  end

  defp status_record(operation, previous, context) do
    revision = to_string(String.to_integer(previous.revision) + 1)

    current =
      Map.merge(
        previous,
        record(
          operation,
          revision,
          previous.idempotency_key,
          previous.pending_action_ref,
          context
        )
      )

    if is_nil(previous.pending_action_ref) and
         match?(%{"state" => "action_required"}, previous.snapshot.peer),
       do: %{current | snapshot: ready_to_deposit(operation, revision, context)},
       else: current
  end

  defp read_facts(operation, record, context) do
    # Status is an external boundary too, including the read preceding withdrawal.
    :ok = Checkpoint.put(context.checkpoint, key(operation), record)

    with {:ok, mapping} <- Mapping.fetch_maker(context, operation) do
      io(context, :reconcile, [
        operation,
        Map.put(mapping, :requested_action_ref, record.pending_action_ref)
      ])
    end
  end

  defp reconciliation_result(operation, record, %{state: :reverted}, context) do
    release_reservation(record, context)
    snapshot = snapshot(operation, record.revision, "failed", [], context)
    closed = Recovery.close(%{record | snapshot: snapshot, pending_action_ref: nil})
    with :ok <- Checkpoint.put(context.checkpoint, key(operation), closed), do: {:ok, snapshot}
  end

  defp reconciliation_result(operation, record, %{state: :approval_confirmed}, context) do
    release_reservation(record, context)

    clear_pending(
      operation,
      record,
      ready_to_deposit(operation, record.revision, context),
      context
    )
  end

  defp reconciliation_result(operation, record, %{state: :unsubmitted}, context) do
    release_reservation(record, context)
    {:ok, mapping} = Mapping.fetch_maker(context, operation)

    snapshot =
      if mapping[:deposit_id] do
        snapshot(
          operation,
          record.revision,
          "processing",
          ["check_status", "recover_peer"],
          context
        )
      else
        ready_to_deposit(operation, record.revision, context)
      end

    clear_pending(operation, record, snapshot, context)
  end

  defp reconciliation_result(operation, record, facts, context) do
    finish_facts(operation, record, facts, context)
  end

  defp clear_pending(operation, record, snapshot, context) do
    :ok =
      Checkpoint.put(context.checkpoint, key(operation), %{
        record
        | snapshot: snapshot,
          pending_action_ref: nil
      })

    {:ok, snapshot}
  end

  defp release_reservation(record, context) do
    if record.pending_action_ref,
      do: SpendGate.release_by_intent(class_context(context), record.pending_action_ref)
  end

  defp ready_to_deposit(operation, revision, context),
    do:
      snapshot(operation, revision, "action_required", ["recover_peer", "check_status"], context)

  defp reconcile_facts(operation, record, context) do
    uncertain(record, fn ->
      case read_facts(operation, record, context) do
        {:ok, facts} -> reconciliation_result(operation, record, facts, context)
        _ -> {:ok, record.snapshot}
      end
    end)
  end

  defp finish_facts(operation, record, facts, context) do
    with {:ok, mapping} <- Mapping.fetch_maker(context, operation),
         true <- valid_facts?(facts, mapping),
         :ok <-
           Mapping.put_maker(
             context,
             operation,
             Map.merge(mapping, Map.take(facts, [:deposit_id, :order_id]))
           ) do
      {state, actions} = normalized(facts)
      snapshot = snapshot(operation, record.revision, state, actions, context)

      :ok =
        Checkpoint.put(
          context.checkpoint,
          key(operation),
          Recovery.close(%{
            record
            | snapshot: snapshot,
              pending_action_ref: nil
          })
        )

      {:ok, snapshot}
    else
      _ -> {:ok, record.snapshot}
    end
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
          "recoverable" => state not in ["completed", "refunded", "failed"]
        },
        "allowed_actions" => actions,
        "updated_at" => DateTime.to_iso8601(now(context)),
        "terminal" => state in ["completed", "refunded", "failed"]
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

  defp reviewed_terms(preview, intent) do
    {preview.quote_id, LiveIO.digest([Ramp.to_wire(preview), Ramp.to_wire(intent)])}
  end

  defp reviewed?({quote, _} = review, review, command),
    do: Map.get(command, :quote_id, quote) == quote

  defp reviewed?({quote, _}, {quote, _}, _command), do: false
  defp reviewed?(_, {quote, _}, command), do: command[:quote_id] == quote

  defp approval(quote, command),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({quote, command}, [:deterministic]))

  defp key(operation), do: "peer_maker:" <> operation
  defp now(context), do: Map.get(context, :now, &DateTime.utc_now/0).()
  defp io(%{maker_io: {module, handle}}, method, args), do: apply(module, method, [handle | args])

  defp wallet(%{maker_wallet: {module, handle}}, method, args),
    do: apply(module, method, [handle | args])

  defp dependencies(context) do
    context
    |> Map.put_new(:maker_io, {Raxol.Payments.Ramp.Peer.LiveIO, context})
    |> Map.put_new(:maker_wallet, {Raxol.Payments.Ramp.Peer.Wallet, context})
  end

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

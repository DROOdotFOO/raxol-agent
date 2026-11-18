defmodule Raxol.Payments.Ramp.Onramp do
  @moduledoc """
  Approval-gated coordinator for the trusted Xochi widget.

  The widget owns all Peer interaction and wallet signatures. The injected
  `:widget` function accepts only an operation, revision and bounded stage and
  returns `:ready`, `:held`, `:released`, `:pending` or `:setup_required`.
  It must authenticate the user and bind the operation to the approved preview.
  `:interaction_ready` must attest the desktop extension or Peer app is ready.
  No provider payload is accepted here. Public action references are correlation
  identifiers, never bearer capabilities. Callers must scope checkpoint stores
  to the authenticated principal. Stores must survive the calling process.

  Every stage is checkpointed before dispatch. An interrupted dispatch is never
  retried; recovery belongs to status reconciliation. Local commands are
  serialized; multi-node stores must provide the same shared lock semantics.
  """
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Checkpoint, Ramp, SpendingPolicy}
  alias Raxol.Payments.Ramp.{Coherence, Recovery}
  alias Raxol.Payments.Ramp.Peer.OnrampReads

  @stages [:intent_signaling, :external_interaction, :proof_finalization, :onchain_submission]

  def approve(operation, quote, command, context) do
    locked(operation, context, fn -> start(operation, quote, command, context) end)
  end

  def resume(operation, action_ref, command, context) do
    locked(operation, context, fn ->
      case Checkpoint.fetch(context.checkpoint, key(operation)) do
        {:ok, record} -> resume_record(record, action_ref, command, context)
        _ -> {:error, :operation_not_found}
      end
    end)
  end

  def status(operation, context) do
    locked(operation, context, fn ->
      case Checkpoint.fetch(context.checkpoint, key(operation)) do
        {:ok, %{snapshot: %{terminal: true}} = record} -> result(record)
        {:ok, record} -> reconcile(record, context)
        _ -> {:error, :operation_not_found}
      end
    end)
  end

  defp resume_record(record, ref, command, context) do
    if ref == record.action_ref and valid_command?(command) do
      resume_current(record, ref, command, context)
    else
      Recovery.conflict(record)
    end
  end

  defp resume_current(record, ref, command, context) do
    cond do
      command[:expected_revision] != record.snapshot.revision ->
        Recovery.conflict(record)

      record.dispatched or record.snapshot.terminal ->
        result(record)

      record[:signal_verified] != true ->
        uncertain(record, context)

      true ->
        case Recovery.claim(context, record.snapshot.operation_id, {:resume, ref}, command) do
          :new -> advance(record, context)
          :replayed -> result(record)
          :conflict -> Recovery.conflict(record)
        end
    end
  end

  defp reconcile(record, context) do
    reader = Map.get(context, :onramp_reader, {OnrampReads, context})
    {module, handle} = reader
    # Status never invokes the widget, signs, or replays a submitted stage.
    case module.reconcile(handle, record.snapshot.operation_id) do
      {:ok, :completed} ->
        reconciled(record, "completed", "released", context)

      {:ok, :held} ->
        reconciled(record, "processing", "held", context)

      {:ok, :processing} ->
        reconciled(record, "processing", nil, context)

      {:ok, :signaled} when record.stage == 0 ->
        updated = %{
          record
          | stage: 1,
            dispatched: false,
            snapshot:
              snapshot(
                record.snapshot.operation_id,
                next_revision(record),
                "action_required",
                context
              )
        }

        verified = Map.put(updated, :signal_verified, true)
        with :ok <- save(verified, context), do: result(verified)

      _ ->
        uncertain(record, context)
    end
  rescue
    _ -> uncertain(record, context)
  catch
    _, _ -> uncertain(record, context)
  end

  defp reconciled(record, state, payout, context) do
    snap = snapshot(record.snapshot.operation_id, next_revision(record), state, context)
    snap = if payout, do: %{snap | peer: Map.put(snap.peer, "payout_state", payout)}, else: snap
    updated = %{record | dispatched: true, snapshot: snap}
    with :ok <- save(updated, context), do: result(updated)
  end

  defp uncertain(%{dispatched: false, signal_verified: true} = record, _context),
    do: result(record)

  defp uncertain(record, context), do: reconciled(record, "in_doubt", nil, context)

  defp locked(operation, %{checkpoint: {_, _}} = context, fun) do
    :global.trans({{__MODULE__, context.checkpoint, operation}, self()}, fun)
  rescue
    _ -> {:error, :coordination_unavailable}
  catch
    _, _ -> {:error, :coordination_unavailable}
  end

  defp locked(_, _, _), do: {:error, :checkpoint_required}

  defp start(operation, quote, command, context) do
    case Checkpoint.fetch(context.checkpoint, key(operation)) do
      {:ok, record} -> replay(record, quote, command, context)
      :error -> begin(operation, quote, command, context)
    end
  end

  defp replay(record, quote, command, context) do
    cond do
      record.quote_id != quote or record.command != command ->
        Recovery.conflict(record)

      record.dispatched or record.snapshot.terminal or record[:signal_verified] == true ->
        result(record)

      true ->
        uncertain(record, context)
    end
  end

  defp begin(operation, quote, command, context) do
    with {:ok, preview} <- valid_preview(operation, quote, context),
         true <- command[:expected_revision] == "0" and valid_command?(command),
         :ok <- Recovery.reserve(context, operation, "onramp"),
         :new <- Recovery.claim(context, operation, {:approve, quote}, command),
         :ok <- authorize(preview, context) do
      start_approved(operation, quote, command, preview, context)
    else
      :conflict -> {:error, :session_conflict}
      :replayed -> {:error, :session_conflict}
      _ -> {:error, :approval_required}
    end
  end

  defp start_approved(operation, quote, command, preview, context) do
    record = %{
      quote_id: quote,
      command: command,
      action_ref: "action_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      stage: 0,
      dispatched: true,
      snapshot: snapshot(operation, "1", "in_doubt", context)
    }

    case reserve_dispatch(record, preview, context) do
      :ok ->
        finish_stage(record, widget(context, :intent_signaling, record.snapshot), context)

      error ->
        SpendGate.release_by_intent(context, operation)
        error
    end
  end

  defp reserve_dispatch(record, preview, context) do
    operation = record.snapshot.operation_id

    with true <- unexpired?(preview, context),
         :ok <- OnrampReads.reserve(context, operation, preview),
         :ok <- Checkpoint.put_new(context.checkpoint, key(operation), record) do
      :ok
    else
      false -> {:error, :approval_required}
      {:error, :capability_changed} = error -> error
      _ -> {:error, :session_conflict}
    end
  rescue
    _ -> {:error, :checkpoint_unavailable}
  catch
    _, _ -> {:error, :checkpoint_unavailable}
  end

  defp valid_preview(operation, quote, context) do
    with true <- context[:interaction_ready] == true,
         %Ramp.Preview{} = preview <- context[:preview],
         {:ok, clean} <- Ramp.decode(Ramp.to_wire(preview)),
         true <- clean.operation_id == operation and clean.quote_id == quote,
         true <- clean.leg_order == ["peer"],
         true <- clean.pay["asset"]["kind"] == "fiat",
         true <- clean.pay["asset"]["currency"] == "USD",
         true <- base_usdc?(clean.receive["asset"]),
         true <- unexpired?(clean, context) do
      {:ok, clean}
    else
      _ -> {:error, :invalid_preview}
    end
  end

  defp unexpired?(preview, context) do
    with {:ok, expiry, 0} <- DateTime.from_iso8601(preview.expires_at),
         do: DateTime.compare(expiry, now(context)) == :gt
  end

  defp base_usdc?(asset) do
    asset["chain_id"] == "eip155:8453" and asset["decimals"] == 6 and
      Coherence.address(asset) == "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  end

  defp authorize(preview, %{policy: %SpendingPolicy{}, on_confirm: confirm} = context)
       when is_function(confirm, 2) do
    amount =
      Decimal.new(1, String.to_integer(preview.pay["atomic"]), -preview.pay["asset"]["decimals"])

    # Require explicit consent even when the policy threshold would auto-approve.
    with :approve <- confirm.(amount, "peer"),
         {:ok, spend} <-
           SpendGate.authorize(Map.put(context, :on_confirm, fn _, _ -> :approve end), amount,
             asset: {:symbol, "USDC"},
             target: {:domain, "peer"}
           ) do
      SpendGate.tag_reservation(context, preview.operation_id, spend)
    else
      _ -> {:error, :approval_required}
    end
  end

  defp authorize(_, _), do: {:error, :approval_required}

  defp advance(%{stage: stage} = record, _) when stage >= 4, do: result(record)

  defp advance(record, context) do
    stage = Enum.at(@stages, record.stage)

    pending = %{
      record
      | dispatched: true,
        snapshot:
          snapshot(record.snapshot.operation_id, next_revision(record), "in_doubt", context)
    }

    case save(pending, context) do
      :ok -> finish_stage(pending, widget(context, stage, pending.snapshot), context)
      _ -> {:error, :checkpoint_unavailable}
    end
  end

  defp widget(context, stage, snapshot) do
    context.widget.(stage, snapshot.operation_id, snapshot.revision)
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp finish_stage(%{stage: 0} = record, :ready, context),
    do: reconcile(record, context)

  defp finish_stage(record, response, context)
       when response == :ready or (record.stage == 3 and response in [:pending, :held, :released]) do
    state = if response == :released, do: "processing", else: "action_required"

    state =
      if response in [:pending, :held] or (record.stage == 3 and response == :ready),
        do: "processing",
        else: state

    snap = snapshot(record.snapshot.operation_id, next_revision(record), state, context)
    payout = if response == :held, do: "held", else: "released"

    snap =
      if response in [:held, :released],
        do: %{snap | peer: Map.put(snap.peer, "payout_state", payout)},
        else: snap

    updated = %{record | stage: record.stage + 1, dispatched: response != :ready, snapshot: snap}
    with :ok <- save(updated, context), do: result(updated)
  end

  defp finish_stage(record, :setup_required, context) do
    updated = %{
      record
      | snapshot: %{
          record.snapshot
          | peer: Map.put(record.snapshot.peer, "failure_code", "setup_required")
        }
    }

    with :ok <- save(updated, context), do: {:error, :setup_required}
  end

  defp finish_stage(record, _, _), do: result(record)

  defp result(%{snapshot: %{peer: %{"failure_code" => "setup_required"}}}),
    do: {:error, :setup_required}

  defp result(%{snapshot: %{peer: %{"state" => "action_required"}}} = record) do
    {:requires_user,
     %{
       action_ref: record.action_ref,
       code: "complete_in_xochi_widget",
       instruction:
         "Complete this step in the trusted Xochi widget using the desktop Peer extension or Peer app."
     }, record.snapshot}
  end

  defp result(record), do: {:ok, record.snapshot}

  defp save(record, context),
    do:
      Checkpoint.put(
        context.checkpoint,
        key(record.snapshot.operation_id),
        Recovery.close(record)
      )

  defp key(operation), do: "peer_onramp:" <> to_string(operation)
  defp next_revision(record), do: to_string(String.to_integer(record.snapshot.revision) + 1)

  defp valid_command?(command) do
    is_map(command) and Enum.sort(Map.keys(command)) == [:expected_revision, :idempotency_key] and
      valid_key?(command[:idempotency_key])
  end

  defp valid_key?(key), do: is_binary(key) and byte_size(key) in 1..128
  defp now(context), do: Map.get(context, :now, &DateTime.utc_now/0).()

  defp actions("completed"), do: []
  defp actions("action_required"), do: ["interact"]
  defp actions(_), do: ["check_status"]

  defp snapshot(operation, revision, state, context) do
    %Ramp.Snapshot{
      contract_version: "ramp/1",
      kind: "snapshot",
      operation_id: operation,
      revision: revision,
      direction: "onramp",
      leg_order: ["peer"],
      peer: %{"name" => "peer", "state" => state, "recoverable" => false},
      allowed_actions: actions(state),
      updated_at: DateTime.to_iso8601(now(context)),
      terminal: state == "completed"
    }
  end
end

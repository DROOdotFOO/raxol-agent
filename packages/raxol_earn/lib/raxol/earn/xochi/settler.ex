defmodule Raxol.Earn.Xochi.Settler do
  @moduledoc """
  Storefront relay: turns `Raxol.Earn.Xochi.SolverAgent`'s `:settle_fn`
  callback into a `Raxol.Payments.Protocols.Xochi.execute_signed/2` call.

  It relays the buyer's pre-signed bundle WITHOUT re-signing and polls it to
  settlement; raxol never signs the transfer or touches the funds.

      settle_fn =
        Raxol.Earn.Xochi.Settler.build(
          xochi_config: %{base_url: "https://api.xochi.fi", auth_token: "..."},
          poll_timeout_ms: 120_000
        )

      Raxol.Earn.Xochi.SolverAgent.start_link(..., settle_fn: settle_fn)

  ## Input shape (from SolverAgent)

      %{
        requirement: %{
          "src_chain_id" => 8453, "dst_chain_id" => 10, "amount_atomic" => "1000000",
          "signed_intent" => %{"intent_id" => "xi_...", "quote_id" => "xq_...",
            "signature" => "0x...", "nonce" => 7, "pull_signature" => "0x..."}
        },
        signed_intent: %{...},             # threaded by SolverAgent
        transfer_amount_atomic: 1_000_000
      }

  ## Output shape

  On settle success:

      {:ok, %{
        intent_id: "abc", settlement_tx_hash: "0x...",
        receiving_tx_hash: "0x...",   # nil for an instant single-tx fill
        amount_atomic: "1000000", status: "completed",
        # stealth settlement only (nil otherwise), ERC-5564 announcement:
        settlement_type: "stealth", stealth_address: "0x...",
        ephemeral_pub_key: "0x...", view_tag: 42
      }}

  On error `{:error, reason}`, and SolverAgent submits no deliverable. A completed
  status with no tx hash is `{:error, {:settlement_tx_hash_unavailable, intent_id}}`.

  ## Read token

  For a stealth/shielded intent the worker withholds tx hashes from anonymous
  callers. The relay presents the execute-time read token while polling but
  never returns, logs, or stores it in a replayable record; with a checkpoint
  store it lives in a separate private record keyed by API origin, bundle
  fingerprint and intent id, expiring after one hour.

  ## Crash recovery

  With a `:checkpoint` store (`Raxol.Payments.Checkpoint` `{module, handle}`) the
  exact bundle is recorded before relaying, and a re-run resumes polling rather
  than relaying again. After submission starts, resets, malformed and 5xx
  responses stay in doubt; a 404 at or after the signed deadline resolves it as
  never dispatched; failures proven pre-send delete the state. Another writer's
  claim on the intent is a definite failure, never adopted. A terminal result
  (never the token) is committed before the token is deleted and returned to
  re-runs for 24 hours.
  """

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.{Client, ReadTokenStore, SettlementState}
  alias Raxol.Payments.Xochi.Schemas.{ExecuteRequest, ExecuteResponse, IntentStatus}

  @doc """
  Build a settle_fn closure.

  ## Required

  - `:xochi_config` -- the Xochi worker config (base_url + auth). The buyer's
    intent is relayed and polled through this endpoint.

  ## Optional

  - `:poll_timeout_ms` -- max time to wait for intent settlement.
    Default 120_000 (2 minutes).
  - `:poll_interval_ms` -- default 2_000 (2 seconds).
  - `:checkpoint` -- a trusted `Raxol.Payments.Checkpoint` store for replay
    recovery and separate `Secret`-wrapped read-token state. Default nil.
  """
  @spec build(keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def build(opts) do
    # Captured by the returned closure, so the member token is wrapped first.
    xochi_config =
      opts |> Keyword.fetch!(:xochi_config) |> Raxol.Payments.Xochi.Client.protect_config()

    poll_timeout = Keyword.get(opts, :poll_timeout_ms, 120_000)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 2_000)
    store = Keyword.get(opts, :checkpoint)
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:second) end)

    fn settle_args ->
      do_settle(settle_args, xochi_config, store, clock,
        timeout_ms: poll_timeout,
        interval_ms: poll_interval
      )
    end
  end

  defp do_settle(args, xochi_config, store, clock, poll_opts) do
    with {:ok, bundle} <- extract_signed_intent(args),
         {:ok, intent_id} <- bundle_intent_id(bundle),
         :ok <- Client.validate_config(xochi_config),
         {:ok, request} <- Xochi.prepare_signed_execute(bundle) do
      settle_request(%{
        args: args,
        clock: clock,
        config: xochi_config,
        key: dispatch_key(xochi_config, intent_id),
        poll_opts: poll_opts,
        principal: SettlementState.fingerprint(request),
        request: request,
        store: store
      })
    end
  end

  defp settle_request(settlement) do
    result =
      dispatch(
        settlement.config,
        settlement.request,
        settlement.principal,
        settlement.store,
        settlement.key,
        settlement.clock.()
      )

    case result do
      {:terminal, terminal} -> terminal
      {:ok, %ExecuteResponse{} = exec} -> poll(settlement, exec)
      {:error, _reason} = error -> error
    end
  end

  defp poll(settlement, exec) do
    now = settlement.clock.()

    token =
      exec.read_token ||
        ReadTokenStore.fetch(
          settlement.store,
          settlement.config.base_url,
          settlement.principal,
          exec.intent_id,
          now
        )

    case Xochi.poll_status(
           settlement.config,
           exec.intent_id,
           Keyword.put(settlement.poll_opts, :read_token, token)
         ) do
      {:ok, %IntentStatus{} = status} ->
        result = settle_result(status, exec, settlement.args)

        SettlementState.commit_terminal(
          settlement.store,
          settlement.config.base_url,
          settlement.principal,
          exec.intent_id,
          result,
          settlement.clock.()
        )

        Checkpoint.delete(settlement.store, settlement.key)
        result

      {:error, {:http, 404, _body}} = error ->
        if expired?(settlement.request.deadline, settlement.clock.()) do
          release_never_dispatched(
            settlement.store,
            settlement.config,
            settlement.principal,
            exec.intent_id,
            settlement.key
          )

          {:error, {:never_dispatched, exec.intent_id}}
        else
          error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp dispatch(xochi_config, request, principal, store, key, now) do
    terminal =
      SettlementState.terminal(store, xochi_config.base_url, principal, request.intent_id, now)

    case terminal do
      {:ok, result} -> {:terminal, result}
      :error -> acquire_dispatch(xochi_config, request, principal, store, key, now)
    end
  end

  defp acquire_dispatch(xochi_config, request, _principal, nil, _key, _now) do
    with :ok <- Client.validate_config(xochi_config) do
      safe_dispatch(xochi_config, request, request.intent_id)
    end
  end

  defp acquire_dispatch(xochi_config, request, principal, store, key, now) do
    with :ok <- Client.validate_config(xochi_config) do
      record = dispatched_record(request, principal, now)

      case Checkpoint.put_new(store, key, record) do
        :ok ->
          dispatch_owned(xochi_config, request, principal, store, key, now)

        {:error, :exists} ->
          resume_owned(xochi_config, request, principal, store, key, now)
      end
    end
  end

  defp dispatch_owned(xochi_config, request, principal, store, key, now) do
    case safe_dispatch(xochi_config, request, request.intent_id) do
      {:ok, %ExecuteResponse{} = exec} ->
        resolved_id = exec.intent_id || request.intent_id

        SettlementState.bind(
          store,
          xochi_config.base_url,
          principal,
          resolved_id,
          request.deadline,
          now,
          dispatch_key: key
        )

        ReadTokenStore.put(
          store,
          xochi_config.base_url,
          principal,
          resolved_id,
          exec.read_token,
          now
        )

        record_executed(store, key, exec, request, principal)

      {:error, _reason} = error ->
        delete_owned(store, key, principal)
        error
    end
  end

  defp resume_owned(xochi_config, request, principal, store, key, now) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{principal: ^principal, status: :dispatching, deadline: deadline}}
      when not is_integer(deadline) or now < deadline ->
        {:error, {:intent_dispatch_in_progress, request.intent_id}}

      {:ok, %{principal: ^principal} = record} ->
        {:ok, resumed_exec(record, request.intent_id, xochi_config, principal, store, now)}

      {:ok, _other_writer} ->
        {:error, {:intent_owned_by_another_writer, request.intent_id}}

      :error ->
        acquire_dispatch(xochi_config, request, principal, store, key, now)
    end
  end

  defp record_executed(store, key, exec, request, principal) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{principal: ^principal} = existing} ->
        record = Map.merge(existing, executed_record(exec, request, principal), &keep_known/3)
        Checkpoint.put(store, key, record)
        {:ok, announced_exec(exec, record)}

      _ ->
        {:error, {:checkpoint_ownership_lost, request.intent_id}}
    end
  end

  defp keep_known(_field, old, nil), do: old
  defp keep_known(_field, _old, new), do: new

  defp announced_exec(%ExecuteResponse{} = exec, record) do
    %{
      exec
      | stealth_address: record.stealth_address,
        ephemeral_pub_key: record.ephemeral_pub_key,
        view_tag: record.view_tag
    }
  end

  defp safe_dispatch(xochi_config, %ExecuteRequest{} = request, intent_id) do
    Xochi.execute_prepared(xochi_config, request)
  rescue
    _exception -> {:ok, in_doubt(intent_id)}
  catch
    _kind, _reason -> {:ok, in_doubt(intent_id)}
  end

  defp in_doubt(intent_id) do
    %ExecuteResponse{
      intent_id: intent_id,
      status: :unknown,
      error: "response_exception",
      reconciling: true
    }
  end

  defp dispatched_record(request, principal, now) do
    %{
      intent_id: request.intent_id,
      status: :dispatching,
      principal: principal,
      deadline: request.deadline,
      expires_at: max(request.deadline || now, now) + 86_400
    }
  end

  defp executed_record(%ExecuteResponse{} = exec, request, principal) do
    %{
      intent_id: exec.intent_id || request.intent_id,
      status: :in_flight,
      principal: principal,
      deadline: request.deadline,
      stealth_address: exec.stealth_address,
      ephemeral_pub_key: exec.ephemeral_pub_key,
      view_tag: exec.view_tag
    }
  end

  defp resumed_exec(record, intent_id, xochi_config, principal, store, now) do
    resolved_id = Map.get(record, :intent_id, intent_id)

    %ExecuteResponse{
      intent_id: resolved_id,
      status: :unknown,
      reconciling: true,
      read_token: ReadTokenStore.fetch(store, xochi_config.base_url, principal, resolved_id, now),
      stealth_address: Map.get(record, :stealth_address),
      ephemeral_pub_key: Map.get(record, :ephemeral_pub_key),
      view_tag: Map.get(record, :view_tag)
    }
  end

  defp delete_owned(store, key, principal) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{principal: ^principal}} -> Checkpoint.delete(store, key)
      _ -> :ok
    end
  end

  defp release_never_dispatched(store, config, principal, intent_id, key) do
    delete_owned(store, key, principal)
    SettlementState.forget(store, config.base_url, principal, intent_id)
    ReadTokenStore.delete(store, config.base_url, principal, intent_id)
  end

  defp expired?(deadline, now) when is_integer(deadline), do: now >= deadline
  defp expired?(_deadline, _now), do: false

  defp dispatch_key(config, intent_id) do
    Checkpoint.derive_key([:xochi_settler, ReadTokenStore.origin(config.base_url), intent_id])
  end

  # The buyer's pre-signed intent bundle, threaded directly (`:signed_intent`) or
  # carried in the requirement JSON (`requirement["signed_intent"]`). Keys may be
  # atoms or strings; `execute_signed/2` normalizes and deep-validates them.
  defp extract_signed_intent(%{signed_intent: bundle}) when is_map(bundle), do: {:ok, bundle}

  defp extract_signed_intent(%{requirement: %{"signed_intent" => bundle}}) when is_map(bundle),
    do: {:ok, bundle}

  defp extract_signed_intent(_), do: {:error, :missing_signed_intent}

  # The status is polled by the intent id the buyer signed (present under either
  # key). `execute_signed/2` re-validates it, so an absent/blank id also fails
  # there; checking here lets a malformed bundle fail before the relay POST.
  defp bundle_intent_id(bundle) do
    case bundle[:intent_id] || bundle["intent_id"] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:invalid_signed_intent, :intent_id}}
    end
  end

  # Only a completed settlement yields a deliverable. A terminal :failed or
  # :expired intent (which poll_status returns as `{:ok, status}`) must surface
  # as an error so SolverAgent does not submit a deliverable for a settlement
  # that never landed.
  defp settle_result(%IntentStatus{status: :completed} = status, exec, args),
    do: to_deliverable(status, exec, args)

  defp settle_result(%IntentStatus{status: s, intent_id: id, error: err}, _exec, _args)
       when s in [:failed, :expired],
       do: {:error, {:settlement_failed, s, id, err}}

  defp settle_result(%IntentStatus{status: s, intent_id: id}, _exec, _args),
    do: {:error, {:settlement_incomplete, s, id}}

  # `IntentStatus.tx_hash` is the authoritative settlement tx: for an instant fill
  # it is the destination delivery; for a two-leg bridge it is the origin leg,
  # with the destination arrival in `receiving_tx_hash` (nil for instant). Surface
  # both under names that match that meaning, rather than a src/dst pair that
  # mislabels the single instant-fill tx as the source leg. `amount_atomic` is the
  # buyer's declared transfer amount, committed so the deliverable hash pins what
  # was moved rather than only the tx hashes.
  #
  # For a stealth settlement the worker returns the ERC-5564 announcement
  # (`stealth_address`/`ephemeral_pub_key`/`view_tag`) on the execute response and
  # marks the settled intent `settlement_type: :stealth` on poll. These are the
  # public on-chain announcement fields the buyer or evaluator needs to verify the
  # delivery, not the recipient's identity; they are nil for a public settlement,
  # so `TransferOffering.present/1` drops them and a public deliverable is
  # byte-identical.
  #
  # A completed status without `tx_hash` is refused, never filled in. The
  # worker omits a stealth/shielded intent's legs unless the
  # caller presents the read token (or owner JWT); the relay presents the token
  # it got from execute, so this fires only when the worker withheld anyway
  # (token absent or rejected) or served none. The Riddler SPEC (§3.4) lets a
  # status omit `txHash`, but the deliverable this builds follows
  # `Offering.deliverable_schema/0,1`, which requires `settlement_tx_hash` (a
  # 32-byte hex hash) in every mode. So the field stays required and the settle
  # fails with the intent id for an operator to reconcile, rather than submit
  # a deliverable that fails its own schema. `receiving_tx_hash` is optional
  # there and is simply dropped when absent.
  defp to_deliverable(%IntentStatus{tx_hash: hash} = status, _exec, _args)
       when not is_binary(hash) or hash == "",
       do: {:error, {:settlement_tx_hash_unavailable, status.intent_id}}

  defp to_deliverable(%IntentStatus{} = status, %ExecuteResponse{} = exec, args) do
    {:ok,
     %{
       intent_id: status.intent_id,
       settlement_tx_hash: status.tx_hash,
       receiving_tx_hash: status.receiving_tx_hash,
       amount_atomic: transfer_amount(args),
       status: to_string(status.status),
       settlement_type: settlement_type(status),
       stealth_address: exec.stealth_address,
       ephemeral_pub_key: exec.ephemeral_pub_key,
       view_tag: exec.view_tag
     }}
  end

  defp settlement_type(%IntentStatus{settlement_type: nil}), do: nil
  defp settlement_type(%IntentStatus{settlement_type: t}), do: to_string(t)

  # The deliverable's amount: the SolverAgent-threaded transfer amount, else the
  # requirement's declared amount. It is display/audit metadata only -- the
  # on-chain amount is fixed by the buyer's signed intent, not by this field.
  defp transfer_amount(%{transfer_amount_atomic: n}) when is_integer(n),
    do: Integer.to_string(n)

  defp transfer_amount(%{requirement: %{"amount_atomic" => a}}), do: a

  defp transfer_amount(_), do: nil
end

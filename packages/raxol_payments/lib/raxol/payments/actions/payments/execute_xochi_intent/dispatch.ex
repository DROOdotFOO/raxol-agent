defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntent.Dispatch do
  @moduledoc false
  # Sign, checkpoint and submit a quoted Xochi intent under an already-reserved
  # spend, for `ExecuteXochiIntent`.
  #
  # The dispatched intent is checkpointed before submit, so a crash during
  # submit leaves a record a resumed run can poll instead of re-signing. A
  # signing failure is proven local and releases the reservation; once
  # submission starts, an exception or ambiguous outcome stays in doubt, since
  # retrying or releasing then could double-spend or free already-spent budget.

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent.Floor
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.{Client, ReadTokenStore, SettlementState}
  alias Raxol.Payments.Xochi.Schemas.{ExecuteResponse, QuoteRequest, QuoteResponse}

  @typedoc """
  One logical payment: the reserved `amount`, the idempotency `store` and
  `key`, and what signing and submitting need.
  """
  @type t :: %{
          required(:config) => Client.config(),
          required(:request) => QuoteRequest.t(),
          required(:floor) => Floor.t(),
          required(:wallet) => module(),
          required(:context) => map(),
          required(:amount) => term(),
          required(:store) => Checkpoint.store() | nil,
          required(:key) => Checkpoint.key()
        }

  @type result ::
          {:ok, ExecuteResponse.t(), QuoteResponse.t()}
          | {:error, term()}

  # A checkpoint outlives the intent deadline by a day for reconciliation.
  @record_ttl_seconds 86_400

  @doc "A solvable quote for `request`, or the reason there is none."
  @spec solvable_quote(Client.config(), QuoteRequest.t()) ::
          {:ok, QuoteResponse.t()} | {:error, term()}
  def solvable_quote(config, request) do
    case Xochi.get_quote(config, request) do
      {:ok, %QuoteResponse{can_solve: true} = quote} -> {:ok, quote}
      {:ok, %QuoteResponse{error: err}} -> {:error, {:cannot_solve, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Execute `quote`. Load-balanced Riddler nodes occasionally miss a freshly
  issued quote and reject the execute as expired; that re-quotes and
  re-executes once under the same reservation.
  """
  @spec execute(t(), QuoteResponse.t()) :: result()
  def execute(payment, %QuoteResponse{} = quote) do
    case submit(payment, quote) do
      {:ok, _exec, _quote} = dispatched ->
        dispatched

      # Already released and nothing dispatched; the checkpoint is not ours.
      {:refused, reason} ->
        {:error, reason}

      {:error, reason} ->
        if quote_expired?(reason), do: retry(payment), else: release_and_clear(payment, reason)
    end
  end

  # The re-quote is held to the same method and floor checks. A refusal
  # releases the reservation and reports itself, not as an execute failure.
  defp retry(payment) do
    with {:ok, quote} <- solvable_quote(payment.config, payment.request),
         :ok <-
           quote
           |> Floor.assert_quote(payment.request, payment.floor)
           |> refuse_retry(payment),
         {:ok, _exec, _quote} = dispatched <- submit(payment, quote) do
      dispatched
    else
      {:refused, reason} -> {:error, reason}
      {:error, reason} -> release_and_clear(payment, reason)
    end
  end

  defp submit(payment, quote) do
    with {:ok, bundle} <- safe_sign(quote, payment.wallet, payment.request) do
      dispatch = %{
        payment: payment,
        bundle: bundle,
        now: now(payment.context),
        principal: SettlementState.principal(payment.context, payment.wallet),
        quote: quote
      }

      acquire(dispatch)
    end
  end

  defp acquire(%{payment: payment} = dispatch) do
    record =
      dispatched_record(
        dispatch.quote,
        dispatch.principal,
        dispatch.bundle[:deadline],
        dispatch.now
      )

    case Checkpoint.put_new(payment.store, payment.key, record) do
      :ok ->
        bind_owner(dispatch)
        dispatch_owned(dispatch)

      # Another run of this payment holds the key, so this run's reservation is
      # released here, once. When that run's record is already gone there is
      # nothing to resume: this run stops without sending, as a refusal the
      # caller does not release again.
      {:error, :exists} ->
        SpendGate.release(payment.context, payment.amount, %{
          protocol: :xochi,
          reason: :concurrent_dispatch
        })

        case Checkpoint.fetch(payment.store, payment.key) do
          {:ok, existing} -> {:ok, resumed_execute(existing), dispatch.quote}
          :error -> {:refused, :checkpoint_race}
        end
    end
  end

  defp dispatched_record(%QuoteResponse{} = quote, principal, deadline, now) do
    %{
      intent_id: quote.intent_id,
      quote_id: quote.quote_id,
      status: :dispatched,
      principal: principal,
      deadline: deadline,
      expires_at: max(deadline || now, now) + @record_ttl_seconds
    }
  end

  defp bind_owner(%{payment: payment} = dispatch) do
    SettlementState.bind(
      payment.store,
      payment.config.base_url,
      dispatch.principal,
      dispatch.quote.intent_id,
      dispatch.bundle[:deadline],
      dispatch.now,
      dispatch_key: payment.key
    )
  end

  defp dispatch_owned(%{payment: payment} = dispatch) do
    intent_id = dispatch.quote.intent_id

    result =
      payment.config
      |> safe_execute(dispatch.bundle, intent_id)
      |> Xochi.as_dispatched(intent_id)

    case result do
      {:ok, exec} ->
        bind_owner(dispatch)

        ReadTokenStore.put(
          payment.store,
          payment.config.base_url,
          dispatch.principal,
          exec.intent_id,
          exec.read_token,
          dispatch.now
        )

        tag(payment.context, exec, payment.amount)
        {:ok, exec, dispatch.quote}

      {:error, _reason} = error ->
        clear_owned(payment, dispatch.principal, intent_id)
        error
    end
  end

  defp resumed_execute(record) do
    %ExecuteResponse{
      intent_id: record.intent_id,
      status: Map.get(record, :status, :unknown),
      reconciling: true
    }
  end

  defp clear_owned(%{store: store, key: key, config: config}, principal, intent_id) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{principal: ^principal}} ->
        Checkpoint.delete(store, key)
        SettlementState.forget(store, config.base_url, principal, intent_id)
        ReadTokenStore.delete(store, config.base_url, principal, intent_id)

      _ ->
        :ok
    end
  end

  defp now(context) do
    context
    |> Map.get(:clock, fn -> System.system_time(:second) end)
    |> then(fn clock -> clock.() end)
  end

  defp safe_sign(quote, wallet, request) do
    Xochi.sign_intent(quote, wallet, request)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  defp safe_execute(config, bundle, intent_id) do
    Xochi.execute_signed(config, bundle)
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

  defp refuse_retry(:ok, _payment), do: :ok

  defp refuse_retry({:error, reason}, payment) do
    SpendGate.release(payment.context, payment.amount, %{
      protocol: :xochi,
      reason: :requote_refused
    })

    Checkpoint.delete(payment.store, payment.key)
    {:refused, reason}
  end

  # A proven local failure or clean server rejection means nothing dispatched:
  # release the reservation and let a later retry start clean.
  defp release_and_clear(payment, reason) do
    SpendGate.release(payment.context, payment.amount, %{
      protocol: :xochi,
      reason: :execute_failed
    })

    Checkpoint.delete(payment.store, payment.key)
    {:error, {:execute_failed, reason}}
  end

  # Bind the reserved amount to the intent id so a later refund (observed by
  # PollXochiStatus) releases exactly this reservation, idempotently.
  defp tag(context, %{intent_id: intent_id}, amount) do
    if is_binary(intent_id), do: SpendGate.tag_reservation(context, intent_id, amount), else: :ok
  end

  defp quote_expired?({:http, _status, body}) when is_map(body) do
    code = to_string(body["error"] || body["reason"] || "")
    message = to_string(body["message"] || "")

    String.contains?(code, "quote_expired") or code == "not_found" or
      String.contains?(String.downcase(message), "expired")
  end

  defp quote_expired?(_reason), do: false
end

defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntent do
  @moduledoc """
  Agent Action that runs a cross-chain (and optionally stealth) Xochi intent.

  Quotes the intent, binds the served EIP-712 intent to the request
  (`Protocols.Xochi.validate_intent/2`) and checks the delivery floor,
  authorizes the spend through `SpendGate` before any signature is released,
  signs and submits via the wallet, and returns the intent id and initial
  status. Poll for the terminal status with
  `Raxol.Payments.Actions.Payments.PollXochiStatus`.

  `amount` is a human amount of `from_token`, scaled to atomic units by the
  token's registered decimals. `SpendGate` prices it in the spending policy's
  unit (`Raxol.Payments.SpendPricing`) and reserves that, or refuses the intent
  as `{:unpriced_asset, detail}` before anything is signed. With
  `swap_kind: "exact_output"` the caller fixes the delivered `output_amount`
  instead, and `amount` is the most the caller will spend: what the gate
  reserves and the ceiling the signed `fromAmount` is held to.

  A proven local failure (bad endpoint config, a connection refused before
  send, a signing failure) or a structurally valid clean server rejection
  releases the reservation and deletes the checkpoint. Once submission may have
  started, a reset, malformed response or 5xx stays in doubt: it is reported as
  dispatched with `reconciling: true`, and the checkpoint and reservation remain
  for polling or operator reconciliation. A 409 or 400 saying another writer
  claimed or completed the intent is a clean rejection for this writer.

  ## Idempotent recovery

  With a `:checkpoint` store, the intent is checkpointed by a stable
  idempotency key before submit, so a run after a crash returns the in-flight
  intent to poll instead of signing again. The execute-time read token is kept
  in a separate private record keyed by API origin, principal (`:agent_id`,
  else the wallet address) and intent id; it never enters the result. Without a
  store the settlement proceeds unchecked and emits
  `[:raxol, :payments, :xochi, :unchecked_settlement]`; `require_checkpoint:
  true` (or `config :raxol_payments, :require_checkpoint`, defaulting to
  `Raxol.Payments.Deployment.production?/0`) fails closed instead with
  `{:error, {:checkpoint_required, _}}`.

  ## Context keys

  * `:wallet` -- wallet module signing the EIP-712 intent.
  * `:xochi_config` -- `%{base_url:, auth:}` for `Xochi.Client`.
  * `:policy`, `:ledger`, `:agent_id`, `:on_confirm` -- see `SpendGate`.
  * `:checkpoint` -- optional trusted `{module, handle}`
    `Raxol.Payments.Checkpoint` store (nil disables recovery).
  * `:require_checkpoint` -- fail closed without a `:checkpoint` store.
  * `:idempotency_key` -- optional explicit key; derived from the payment
    when absent.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_execute_xochi_intent",
    sensitive: true,
    description:
      "Execute a cross-chain or stealth payment through Xochi: quote, authorize the spend, sign the EIP-712 intent, and submit. Returns the intent id and status to poll.",
    schema: [
      input: [
        amount: [
          type: :string,
          required: true,
          description:
            "Human-decimal amount to send, e.g. \"1.00\". With swap_kind exact_output, the most to spend."
        ],
        from_chain_id: [type: :integer, required: true],
        to_chain_id: [type: :integer, required: true],
        from_token: [
          type: :string,
          required: true,
          description: "Source token contract (0x...)"
        ],
        to_token: [
          type: :string,
          required: true,
          description: "Destination token contract (0x...)"
        ],
        settlement: [
          type: :string,
          description: "public | stealth | shielded (default: stealth)"
        ],
        recipient_meta_address: [
          type: :string,
          description: "Recipient ERC-6538 stealth meta-address (st:eth:0x...)"
        ],
        recipient_address: [
          type: :string,
          description:
            "Destination recipient for a plaintext (public) transfer. Required for a cross-VM route; omit for same-VM, where Xochi defaults it to the sending wallet."
        ],
        swap_kind: [
          type: :string,
          description:
            "exact_input (default): send exactly `amount`. exact_output: deliver exactly `output_amount`, spending at most `amount`."
        ],
        output_amount: [
          type: :string,
          description:
            "exact_output only: the amount to deliver, as a string of digits in destination-chain atomic units."
        ],
        slippage_bps: [type: :integer, default: 50, description: "Max slippage (default 50)"],
        trust_score: [type: :integer, description: "Trust score for tier/fee"],
        min_to_amount: [
          type: :string,
          description:
            "Optional minimum acceptable delivery, as a string of positive digits in destination-chain atomic units (anything else, \"0\" included, is refused; the Relay tool and the deposit route read \"0\" as absent instead). A quote delivering less is rejected before signing. Required to bound a cross-asset corridor, and on a non-USD stablecoin destination it must be in that token's units; on a same-asset corridor it can only raise the automatic 80%-of-par floor, never lower it."
        ]
      ],
      output: [
        intent_id: [type: :string],
        status: [type: :string],
        from_amount: [type: :string],
        to_amount: [type: :string],
        xochi_fee: [type: :string],
        stealth_address: [type: :string],
        reconciling: [
          type: :boolean,
          description:
            "True when the settlement is in doubt: the worker could not confirm the solver executed, so the intent stays non-terminal. Poll the intent status to resolve; do not re-execute."
        ]
      ]
    ]

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent.{Dispatch, Floor}
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Assets, Checkpoint, Failure, Router}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.{Client, Stealth, SwapAnnouncer}
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(params, context) do
    with {:ok, wallet} <- fetch(context, :wallet),
         {:ok, config} <- fetch(context, :xochi_config),
         :ok <- Client.validate_config(config),
         {:ok, request, amount} <- build_request(params, wallet),
         {:ok, store} <- resolve_checkpoint(context, request) do
      resume_or_settle(config, wallet, request, amount, params, context, store)
    end
    |> normalize_error()
  end

  defp resume_or_settle(config, wallet, request, amount, params, context, store) do
    key = idempotency_key(context, request)

    case Checkpoint.fetch(store, key) do
      # Already in flight from a run that crashed before confirming: return the
      # recorded intent without reserving budget or signing again.
      {:ok, record} -> {:ok, resume_summary(record)}
      :error -> settle(config, wallet, request, amount, params, context, store, key)
    end
  end

  defp normalize_error({:ok, _result} = ok), do: ok
  defp normalize_error({:error, reason}), do: {:error, Failure.from(reason)}

  defp settle(config, wallet, request, amount, params, context, store, key) do
    with :ok <- assert_xochi_route(params),
         {:ok, floor} <- Floor.delivery_floor(request, params),
         {:ok, quote} <- Dispatch.solvable_quote(config, request),
         :ok <- Floor.assert_quote(quote, request, floor),
         {:ok, reserved} <- authorize(context, config, request, amount),
         {:ok, exec, filled_quote} <-
           Dispatch.run(
             %{
               config: config,
               request: request,
               floor: floor,
               wallet: wallet,
               context: context,
               amount: reserved,
               store: store,
               key: key
             },
             quote
           ),
         :ok <- assert_settlement_privacy(request, exec) do
      record_settled(context, request, filled_quote, exec, store, key)
    end
  end

  defp record_settled(context, request, filled_quote, exec, store, key) do
    # On exact_output the request carries no origin amount; report the one the
    # signed intent bound (equal to the request's on exact_input).
    reported = %{request | from_amount: Xochi.intent_from_amount(filled_quote)}
    summary = summary(reported, filled_quote, exec)
    # Best-effort and non-blocking; a no-op unless a capability topic_id is set.
    SwapAnnouncer.announce_execute(context, reported, filled_quote, exec)

    Checkpoint.put(store, key, %{
      intent_id: summary.intent_id,
      status: :in_flight,
      summary: summary
    })

    {:ok, summary}
  end

  # An in-doubt settlement has no stealth address yet (it appears once the
  # intent completes), so the guard below must not fire; `reconciling` in the
  # summary reports the in-doubt state instead.
  defp assert_settlement_privacy(_request, %{reconciling: true}), do: :ok

  # A stealth settlement must come back with the stealth address the worker
  # derived and announced; nil means the privacy asked for was not delivered.
  # Public and shielded (note-based) settlements have no stealth address.
  defp assert_settlement_privacy(%QuoteRequest{settlement_preference: "stealth"}, %{
         stealth_address: address,
         intent_id: intent_id
       }) do
    if is_binary(address) and address != "",
      do: :ok,
      else: {:error, {:stealth_address_missing, intent_id}}
  end

  defp assert_settlement_privacy(_request, _exec), do: :ok

  defp resolve_checkpoint(context, request) do
    case Map.get(context, :checkpoint) do
      {module, _handle} = store when is_atom(module) ->
        {:ok, store}

      _ ->
        if require_checkpoint?(context) do
          {:error, {:checkpoint_required, :no_idempotency_store}}
        else
          emit_unchecked_settlement(request)
          {:ok, nil}
        end
    end
  end

  defp require_checkpoint?(context) do
    case Map.get(context, :require_checkpoint) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        Application.get_env(
          :raxol_payments,
          :require_checkpoint,
          Raxol.Payments.Deployment.production?()
        )
    end
  end

  defp emit_unchecked_settlement(%QuoteRequest{} = request) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :unchecked_settlement],
      %{},
      %{
        wallet: request.wallet,
        from_chain_id: request.from_chain_id,
        to_chain_id: request.to_chain_id
      }
    )
  end

  # An explicit key lets a caller treat two otherwise-identical payments as
  # distinct; otherwise the key is the canonical payment, recipient included.
  defp idempotency_key(context, %QuoteRequest{} = request) do
    case Map.get(context, :idempotency_key) do
      key when is_binary(key) ->
        key

      _ ->
        Checkpoint.derive_key([
          :xochi,
          request.wallet,
          request.from_chain_id,
          request.to_chain_id,
          request.from_token,
          request.to_token,
          request.from_amount,
          request.swap_kind,
          request.output_amount,
          request.max_from_amount,
          request.recipient_address,
          request.settlement_preference,
          request.stealth_spending_pub_key,
          request.stealth_viewing_pub_key
        ])
    end
  end

  # A crash between the pre-submit checkpoint and the settled record leaves
  # only the dispatched intent; return it so the caller polls it.
  defp resume_summary(%{summary: summary}) when is_map(summary), do: summary

  defp resume_summary(record) do
    %{intent_id: record.intent_id, status: to_string(Map.get(record, :status, :dispatched))}
  end

  defp fetch(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_context, key}}
    end
  end

  defp build_request(params, wallet) do
    amount = Decimal.new(Map.fetch!(params, :amount))
    settlement = settlement(params)

    with {:ok, decimals} <- registered_legs(params),
         :ok <- Floor.validate_min_to_amount(params),
         {:ok, spending_key, viewing_key} <- stealth_keys(settlement, params),
         {:ok, amounts} <- swap_amounts(params, Assets.to_atomic(amount, decimals)) do
      fields =
        params
        |> route_fields()
        |> Map.merge(amounts)
        |> Map.merge(%{
          wallet: wallet.address(),
          settlement_preference: settlement,
          stealth_spending_pub_key: spending_key,
          stealth_viewing_pub_key: viewing_key
        })

      {:ok, struct!(QuoteRequest, fields), amount}
    end
  end

  defp route_fields(params) do
    %{
      from_chain_id: Map.fetch!(params, :from_chain_id),
      to_chain_id: Map.fetch!(params, :to_chain_id),
      from_token: Map.fetch!(params, :from_token),
      to_token: Map.fetch!(params, :to_token),
      recipient_address: Map.get(params, :recipient_address),
      slippage_bps: Map.get(params, :slippage_bps) || 50,
      trust_score: Map.get(params, :trust_score)
    }
  end

  # exact_input sends the atomic `amount`; exact_output sends `output_amount`
  # and holds the solver's origin amount to the atomic `amount` as a ceiling.
  defp swap_amounts(params, atomic) do
    case Map.get(params, :swap_kind) || "exact_input" do
      "exact_input" ->
        {:ok, %{swap_kind: "exact_input", from_amount: Integer.to_string(atomic)}}

      "exact_output" ->
        {:ok,
         %{
           swap_kind: "exact_output",
           from_amount: nil,
           output_amount: Map.get(params, :output_amount),
           max_from_amount: Integer.to_string(atomic)
         }}

      other ->
        {:error, {:invalid_swap_kind, other}}
    end
  end

  # Both legs must have registered decimals; returns the source leg's. A guess
  # would move 10^n the intended amount, and a destination amount (a
  # `min_to_amount`, the same-asset floor) means nothing without them.
  defp registered_legs(params) do
    from_chain = Map.fetch!(params, :from_chain_id)
    from_token = Map.fetch!(params, :from_token)

    with {:ok, decimals} <- registered_asset(from_chain, from_token, :source),
         {:ok, _} <-
           registered_asset(
             Map.fetch!(params, :to_chain_id),
             Map.fetch!(params, :to_token),
             :destination
           ) do
      {:ok, decimals}
    end
  end

  defp registered_asset(chain, token, side) do
    case Assets.fetch_decimals(chain, token) do
      {:ok, decimals} -> {:ok, decimals}
      :error -> {:error, {:unknown_asset, %{chain_id: chain, token: token, side: side}}}
    end
  end

  defp settlement(params), do: Map.get(params, :settlement, "stealth")

  # Riddler rejects a stealth quote without the recipient's compressed spending
  # and viewing keys (from their ERC-6538 meta-address) and derives the stealth
  # address and announcement server-side from them.
  defp stealth_keys("stealth", %{recipient_meta_address: meta, to_chain_id: chain})
       when is_binary(meta) do
    case Stealth.decode_meta_address(meta, chain) do
      {:ok, %{spending_pub_key: spending, viewing_pub_key: viewing}} ->
        {:ok, encode_pub_key(spending), encode_pub_key(viewing)}

      {:error, reason} ->
        {:error, {:invalid_meta_address, reason}}
    end
  end

  defp stealth_keys("stealth", _params), do: {:error, :stealth_meta_address_required}
  defp stealth_keys(_settlement, _params), do: {:ok, nil, nil}

  defp encode_pub_key(pub_key), do: "0x" <> Base.encode16(pub_key, case: :lower)

  # Chain ids ride along so chain-aware routing (a Tron leg belongs on Relay)
  # runs here too, not only the privacy/cross-chain split.
  defp assert_xochi_route(params) do
    from_chain = Map.fetch!(params, :from_chain_id)
    to_chain = Map.fetch!(params, :to_chain_id)

    case settlement_atom(settlement(params)) do
      :invalid ->
        {:error, {:invalid_settlement, settlement(params)}}

      privacy ->
        case Router.select(
               cross_chain: from_chain != to_chain,
               privacy: privacy,
               from_chain_id: from_chain,
               to_chain_id: to_chain
             ) do
          :xochi -> :ok
          other -> {:error, {:not_xochi_route, other}}
        end
    end
  end

  defp settlement_atom("public"), do: :public
  defp settlement_atom("stealth"), do: :stealth
  defp settlement_atom("shielded"), do: :shielded
  defp settlement_atom(_), do: :invalid

  # The gate reserves `amount` in the policy's unit; the ledger calls that
  # follow (release, tag) take the reserved amount it returns.
  defp authorize(context, config, request, amount) do
    host = config |> Map.fetch!(:base_url) |> URI.parse() |> Map.get(:host)

    SpendGate.authorize(context, amount,
      asset: {:token, request.from_chain_id, request.from_token},
      target: {:domain, host},
      metadata: %{protocol: :xochi}
    )
  end

  # The stealth address is the one Xochi derived and announced server-side; a
  # client-side derivation would use a different ephemeral key and name an
  # address the funds never landed on. `reconciling` surfaces an in-doubt
  # execute rather than reporting it as a completed payment.
  defp summary(request, quote, exec) do
    %{
      intent_id: exec.intent_id,
      status: to_string(exec.status),
      from_amount: request.from_amount,
      to_amount: quote.to_amount,
      xochi_fee: quote.xochi_fee,
      stealth_address: exec.stealth_address,
      reconciling: exec.reconciling
    }
  end
end

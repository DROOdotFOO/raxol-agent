defmodule Raxol.Payments.Ramp.Peer.LiveIO do
  @moduledoc "Default concrete unsigned maker plans and receipt/protocol reconciliation."
  @behaviour Raxol.Payments.Ramp.Peer.MakerIO
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer.{ABI, Discovery, LiveReads, Mapping, Plans}

  @impl true
  def prepare(context, operation, action, terms, mapping) do
    context = Map.put(context, :maker_operation, operation)

    guarded(fn ->
      plan = expected_plan!(context, action, terms, mapping)

      {:ok,
       Map.merge(plan, %{
         owner: context.user,
         operation_ref: operation,
         requested_action: action,
         expires_at: DateTime.add(LiveReads.now(context), 20),
         review: terms,
         mapping: mapping
       })}
    end)
  end

  def expected_plan!(context, :create_deposit, terms, mapping) do
    true = is_nil(mapping[:deposit_id]) and is_nil(mapping[:creation_tx_hash])
    {:ok, expiry, 0} = DateTime.from_iso8601(terms.preview.expires_at)
    true = DateTime.compare(expiry, LiveReads.now(context)) == :gt
    amount = LiveReads.uint!(terms.amount)
    ^amount = LiveReads.uint!(mapping.total)
    rail = terms.preview |> Map.fetch!(:offer_id) |> rail!(context)
    fresh = LiveReads.terms!(context, terms.intent, rail)
    true = Discovery.revision(fresh, "available") == terms.preview.capability_revision
    true = amount >= fresh.minimum and amount <= fresh.maximum
    true = expected_receive(terms.intent, amount, fresh.rate) == terms.preview.receive["atomic"]
    registration = context[:maker_registrations][rail]

    true =
      registration[:own_account_verified] == true and
        LiveReads.same?(registration[:wallet], context.user)

    true = rail not in ["wise", "paypal", "alipay", "venmo", "cashapp", "xmoney"]
    height = LiveReads.height!(context)

    allowance =
      LiveReads.erc20!(context, "0xdd62ed3e", [context.user, ABI.address("escrowV2")], height)

    if allowance < amount,
      do: Plans.approval(amount),
      else: Plans.deposit(amount, rail, registration.payee_hash, fresh)
  end

  def expected_plan!(context, :withdraw_unmatched, terms, mapping) do
    id = LiveReads.uint!(mapping.deposit_id)
    amount = LiveReads.uint!(terms.amount)
    facts = LiveReads.deposit!(context, id, context.user)
    true = amount > 0 and amount <= LiveReads.uint!(facts.unmatched)
    full = terms.amount == facts.remaining
    true = not full or facts.active_intents == 0
    Plans.withdrawal(id, amount, full)
  end

  def rail!(offer, context) do
    # Offer identity is recomputable from public intent/rail, never a provider handle.
    Enum.find(Map.keys(ABI.config()["rails"]), fn rail ->
      offer == offer_ref(context.intent, rail)
    end) || raise ArgumentError
  end

  def offer_ref(intent, rail), do: "maker_" <> digest([Ramp.to_wire(intent), rail])

  def digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  def expected_receive(intent, amount, rate) do
    scale = Integer.pow(10, 6 - intent.fiat["decimals"])
    to_string(div(amount * rate, Integer.pow(10, 18) * scale))
  end

  @impl true
  def reconcile(context, operation, mapping) do
    context = Map.put(context, :maker_operation, operation)

    guarded(fn ->
      mapping = resolve_pending!(context, operation, mapping)

      result =
        cond do
          mapping[:unsubmitted] == true ->
            %{state: :unsubmitted}

          mapping[:pending_failed] == true and mapping[:pending_kind] != :withdraw_unmatched ->
            %{state: :reverted}

          is_binary(mapping[:deposit_id]) ->
            LiveReads.deposit!(context, LiveReads.uint!(mapping.deposit_id), context.user)

          mapping[:approval_confirmed] == true ->
            %{state: :approval_confirmed}

          true ->
            %{state: :pending}
        end

      {:ok, result}
    end)
  end

  defp resolve_pending!(context, operation, mapping) do
    requested = Map.get(mapping, :requested_action_ref, mapping[:pending_action_ref])

    cond do
      is_nil(requested) ->
        true = is_nil(mapping[:pending_action_ref]) or mapping[:pending_resolved] == true
        mapping

      requested != mapping[:pending_action_ref] ->
        # A crash can leave the new checkpoint ahead of the mapping. Older
        # checkpoints also wrote the mapping only when a hash was available.
        true = is_nil(mapping[:pending_action_ref]) or mapping[:pending_resolved] == true
        Map.put(mapping, :unsubmitted, true)

      is_nil(mapping[:pending_tx_hash]) ->
        resolve_unsubmitted!(context, operation, mapping)

      true ->
        resolve_receipt!(context, operation, mapping)
    end
  end

  defp resolve_unsubmitted!(context, operation, mapping) do
    :ok = verify_unsubmitted!(context, mapping)
    resolved = Map.put(mapping, :pending_resolved, true)
    :ok = Mapping.put_maker(context, operation, resolved)
    Map.put(resolved, :unsubmitted, true)
  end

  defp verify_unsubmitted!(_, %{pending_kind: {:requested, _}}), do: :ok

  defp verify_unsubmitted!(context, %{pending_kind: {:nonce, _, nonce}} = mapping) do
    true = LiveReads.same?(mapping.owner, context.user)
    count = LiveReads.rpc!(context, "eth_getTransactionCount", [context.user, "finalized"])
    true = LiveReads.quantity(count) <= nonce

    case Mapping.release_nonce(
           context.maker_mapping,
           context.user,
           nonce,
           mapping.pending_action_ref
         ) do
      :ok -> :ok
      {:error, :nonce_reserved} -> :ok
    end
  end

  defp resolve_receipt!(context, operation, mapping) do
    hash = mapping[:pending_tx_hash]
    true = is_binary(hash)
    height = LiveReads.height!(context)
    tx = LiveReads.rpc!(context, "eth_getTransactionByHash", [hash])
    receipt = LiveReads.rpc!(context, "eth_getTransactionReceipt", [hash])

    true =
      LiveReads.same?(tx["from"], context.user) and LiveReads.same?(mapping.owner, context.user)

    true = LiveReads.quantity(tx["chainId"]) == 8453

    true =
      LiveReads.same?(tx["to"], mapping.expected_to) and
        ABI.hash(ABI.unhex(tx["input"])) == mapping.expected_input_hash

    true =
      LiveReads.quantity(tx["value"]) == 0 and LiveReads.same?(receipt["transactionHash"], hash)

    finalized = LiveReads.rpc!(context, "eth_getBlockByNumber", ["finalized", false])

    true =
      LiveReads.quantity(receipt["blockNumber"]) <=
        min(height, LiveReads.quantity(finalized["number"])) and
        receipt["status"] in ["0x0", "0x1"]

    resolved =
      if receipt["status"] == "0x0" do
        Map.put(mapping, :pending_failed, true)
      else
        resolve_success!(mapping, receipt, context, hash)
      end

    resolved = Map.merge(resolved, %{pending_resolved: true})
    :ok = Mapping.put_maker(context, operation, resolved)
    resolved
  end

  defp resolve_success!(mapping, receipt, context, hash) do
    case mapping.pending_kind do
      :create_deposit ->
        id = creation_id!(receipt["logs"], context.user, mapping.total)
        Map.merge(mapping, %{deposit_id: to_string(id), creation_tx_hash: hash})

      :approve_usdc ->
        Map.put(mapping, :approval_confirmed, true)

      :withdraw_unmatched ->
        mapping
    end
  end

  defp creation_id!(logs, owner, total) when is_list(logs) and length(logs) <= 1000 do
    event = ABI.function("escrowV2", "DepositReceived")

    topic =
      ABI.hash("DepositReceived(" <> Enum.map_join(event["inputs"], ",", &ABI.type_name/1) <> ")")

    ids = Enum.flat_map(logs, &creation_log(&1, topic, event, owner, total))

    [id] = ids
    id
  end

  defp creation_log(
         %{"address" => address, "topics" => [topic, id, depositor, token], "data" => data},
         topic,
         event,
         owner,
         total
       ) do
    if LiveReads.same?(address, ABI.address("escrowV2")) and
         LiveReads.same?("0x" <> String.slice(depositor, -40, 40), owner) and
         LiveReads.same?("0x" <> String.slice(token, -40, 40), ABI.address("usdc")) do
      specs = Enum.reject(event["inputs"], & &1["indexed"])
      [amount | _] = ABI.decode(specs, ABI.unhex(data))
      true = amount == LiveReads.uint!(total)
      [LiveReads.quantity(id)]
    else
      []
    end
  end

  defp creation_log(_, _, _, _, _), do: []

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :capability_unavailable}
  catch
    _, _ -> {:error, :capability_unavailable}
  end
end

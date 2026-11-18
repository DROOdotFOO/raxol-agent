defmodule Raxol.Payments.Ramp.Peer.OnrampReads do
  @moduledoc """
  Read-only onramp recovery using Base final receipts and the public Peer indexer.

  The trusted widget registers public protocol hashes through `track/3`, never
  through action parameters. Binding terms are captured from the approved preview
  and intent before widget dispatch. Missing mappings or evidence stay in doubt.
  No credentials, proof/session identifiers, calldata or raw responses are stored.
  Deferred payouts use the pinned stake vault lock, as in the SDK payout reader.
  A fulfillment directed to a vault is held until its finalized lock clears.
  """
  alias Raxol.Payments.{Checkpoint, Ramp}
  alias Raxol.Payments.Ramp.Peer.{ABI, Indexer, LiveReads, Mapping}

  @query """
  query OnrampIntent($hash: String!) {
    Intent(where: {intentHash: {_eq: $hash}}, limit: 2) { intentHash amount status releasedAmount orchestratorAddress }
    Orchestrator_V21_IntentFulfilled(where: {intentHash: {_eq: $hash}}, limit: 2) { intentHash amount fundsTransferredTo }
  }
  """

  @signal_window_seconds 300

  def quote_terms(quote, rail, currency) do
    amount = LiveReads.uint!(quote["signalIntentAmount"])
    rate = LiveReads.uint!(quote["conversionRate"])
    deposit = deposit_id!(get_in(quote, ["intent", "depositId"]))

    if amount >= LiveReads.uint!(quote["tokenAmount"]) and amount > 0 and rate > 0 do
      %{
        signal_amount: amount,
        conversion_rate: rate,
        deposit_id: deposit,
        payment_method: ABI.hash(rail),
        fiat_currency: ABI.hash(currency)
      }
    end
  rescue
    _ -> nil
  end

  defp deposit_id!(value) when is_integer(value) and value in 0..9_007_199_254_740_991,
    do: value

  defp deposit_id!(value), do: LiveReads.uint!(value)

  def remember_preview(%{checkpoint: {_, _}, user: owner} = context, preview, intent, terms)
      when is_map(terms) do
    quote =
      Map.merge(terms, %{
        owner: owner,
        recipient: intent.recipient,
        preview_digest: digest(preview),
        total: preview.receive["atomic"]
      })

    case Checkpoint.put_new(context.checkpoint, quote_key(preview.operation_id), quote) do
      :ok -> :ok
      _ -> {:error, :checkpoint_unavailable}
    end
  end

  def remember_preview(_, _, _, _), do: :ok

  def reserve(%{maker_mapping: mapping, user: owner} = context, operation, preview) do
    with {:ok, quote} <- Checkpoint.fetch(context.checkpoint, quote_key(operation)),
         true <- quote.preview_digest == digest(preview),
         true <- LiveReads.same?(quote.owner, owner),
         :ok <-
           Mapping.put(mapping, key(operation), %{
             owner: quote.owner,
             recipient: quote.recipient,
             total: quote.total
           }) do
      approved_at = Map.get(context, :now, &DateTime.utc_now/0).() |> DateTime.to_unix()

      Checkpoint.put_new(
        context.checkpoint,
        approval_key(operation),
        Map.put(quote, :approved_at, approved_at)
      )
    else
      _ -> {:error, :capability_changed}
    end
  end

  def reserve(%{maker_mapping: _}, _, _), do: {:error, :capability_changed}
  def reserve(_, _, _), do: :ok

  defp digest(preview) do
    :crypto.hash(:sha256, :erlang.term_to_binary(Ramp.to_wire(preview), [:deterministic]))
  end

  defp quote_key(operation), do: "peer_onramp_quote:" <> operation
  defp approval_key(operation), do: "peer_onramp_binding:" <> operation

  @doc "Register only public protocol evidence from the authenticated trusted widget."
  def track(context, operation, hashes) do
    :global.trans({{__MODULE__, context.maker_mapping, operation}, self()}, fn ->
      with {:ok, mapping} <- Mapping.fetch(context.maker_mapping, key(operation)),
           true <- LiveReads.same?(mapping.owner, context.user),
           true <- map_size(hashes) > 0,
           true <- valid_hashes?(hashes, mapping) do
        Mapping.put(context.maker_mapping, key(operation), Map.merge(mapping, hashes))
      else
        _ -> {:error, :session_conflict}
      end
    end)
  end

  defp valid_hashes?(hashes, mapping) do
    Enum.all?(hashes, fn {key, value} ->
      key in [:intent_hash, :signal_tx_hash, :settlement_tx_hash] and hash?(value) and
        (is_nil(mapping[key]) or LiveReads.same?(mapping[key], value))
    end)
  end

  def reconcile(context, operation) do
    with {:ok, mapping} <- Mapping.fetch(context.maker_mapping, key(operation)),
         true <- LiveReads.same?(mapping.owner, context.user),
         {:ok, terms} <- Checkpoint.fetch(context.checkpoint, approval_key(operation)),
         true <- LiveReads.same?(terms.owner, mapping.owner),
         true <- LiveReads.same?(terms.recipient, mapping.recipient),
         true <- terms.total == mapping.total,
         true <- hash?(mapping[:intent_hash]) and hash?(mapping[:signal_tx_hash]) do
      height = LiveReads.height!(context)
      signal = receipt!(context, mapping.signal_tx_hash, height)
      signal_timestamp = signaled!(context, signal, mapping, terms)
      {:ok, data} = Indexer.query(context.maker_indexer, @query, %{hash: mapping.intent_hash})
      [intent] = data["Intent"]
      true = LiveReads.same?(intent["intentHash"], mapping.intent_hash)
      true = LiveReads.same?(intent["orchestratorAddress"], ABI.address("orchestratorV4"))
      true = LiveReads.uint!(intent["amount"]) == terms.signal_amount

      case intent["status"] do
        "SIGNALED" ->
          chain =
            LiveReads.read!(context, "orchestratorV4", "getIntent", [mapping.intent_hash], height)

          true = LiveReads.same?(chain["owner"], mapping.owner)
          true = LiveReads.same?(chain["to"], mapping.recipient)
          true = LiveReads.same?(chain["escrow"], ABI.address("escrowV2"))
          true = chain["depositId"] == terms.deposit_id and chain["amount"] == terms.signal_amount
          true = LiveReads.same?(chain["paymentMethod"], terms.payment_method)
          true = LiveReads.same?(chain["fiatCurrency"], terms.fiat_currency)
          true = chain["conversionRate"] == terms.conversion_rate
          true = chain["timestamp"] == signal_timestamp
          {:ok, :signaled}

        "FULFILLED" ->
          fulfilled(context, mapping, intent, data, height)

        _ ->
          {:ok, :in_doubt}
      end
    else
      _ -> {:ok, :in_doubt}
    end
  rescue
    _ -> {:ok, :in_doubt}
  catch
    _, _ -> {:ok, :in_doubt}
  end

  defp fulfilled(context, mapping, intent, data, height) do
    true = hash?(mapping[:settlement_tx_hash])
    receipt = receipt!(context, mapping.settlement_tx_hash, height)
    event = event!(receipt, "IntentFulfilled", mapping.intent_hash)
    [indexed] = data["Orchestrator_V21_IntentFulfilled"]
    true = LiveReads.same?(indexed["intentHash"], mapping.intent_hash)

    [amount, _released_by] =
      ABI.decode(Enum.reject(event.spec["inputs"], & &1["indexed"]), ABI.unhex(event.log["data"]))

    true = amount == LiveReads.uint!(indexed["amount"])
    true = amount == LiveReads.uint!(intent["releasedAmount"])
    [_, _, recipient] = event.log["topics"]
    recipient = "0x" <> String.slice(recipient, -40, 40)
    true = LiveReads.same?(recipient, indexed["fundsTransferredTo"])

    if LiveReads.same?(recipient, mapping.recipient) do
      true = delivered?(receipt, mapping.recipient, LiveReads.uint!(mapping.total))
      {:ok, :completed}
    else
      deferred!(context, receipt, mapping, recipient, height)
    end
  end

  defp deferred!(context, receipt, mapping, vault, height) do
    true = LiveReads.same?(vault, ABI.address("stakeVaultV2"))
    event = event!(receipt, "IntentPayoutDeferred", mapping.intent_hash)
    [_, _, recipient, event_vault] = event.log["topics"]
    true = LiveReads.same?("0x" <> String.slice(recipient, -40, 40), mapping.recipient)
    true = LiveReads.same?("0x" <> String.slice(event_vault, -40, 40), vault)

    [amount] =
      ABI.decode(Enum.reject(event.spec["inputs"], & &1["indexed"]), ABI.unhex(event.log["data"]))

    true = amount == LiveReads.uint!(mapping.total)
    finalized = LiveReads.rpc!(context, "eth_getBlockByNumber", ["finalized", false])

    lock =
      LiveReads.read!(
        context,
        "stakeVaultV2",
        "locks",
        [mapping.intent_hash],
        min(height, LiveReads.quantity(finalized["number"]))
      )

    if lock["stakeOwner"] == "0x" <> String.duplicate("0", 40) do
      true = lock["amount"] == 0 and lock["maturesAt"] == 0
      {:ok, :completed}
    else
      true = LiveReads.same?(lock["stakeOwner"], mapping.recipient) and lock["amount"] == amount
      {:ok, :held}
    end
  end

  defp signaled!(context, receipt, mapping, terms) do
    event = event!(receipt, "IntentSignaled", mapping.intent_hash)

    [method, owner, recipient, amount, currency, rate, timestamp | _] =
      ABI.decode(Enum.reject(event.spec["inputs"], & &1["indexed"]), ABI.unhex(event.log["data"]))

    true = LiveReads.same?(owner, mapping.owner) and LiveReads.same?(recipient, mapping.recipient)
    true = amount == terms.signal_amount and rate == terms.conversion_rate

    true =
      LiveReads.same?(method, terms.payment_method) and
        LiveReads.same?(currency, terms.fiat_currency)

    [_, _, escrow, deposit] = event.log["topics"]
    true = LiveReads.same?("0x" <> String.slice(escrow, -40, 40), ABI.address("escrowV2"))
    true = LiveReads.quantity(deposit) == terms.deposit_id

    block = LiveReads.rpc!(context, "eth_getBlockByNumber", [receipt["blockNumber"], false])
    true = LiveReads.quantity(block["number"]) == LiveReads.quantity(receipt["blockNumber"])
    true = hash?(block["hash"]) and LiveReads.same?(block["hash"], receipt["blockHash"])
    block_timestamp = LiveReads.quantity(block["timestamp"])
    true = block_timestamp >= terms.approved_at
    true = block_timestamp <= terms.approved_at + @signal_window_seconds
    timestamp
  end

  defp receipt!(context, hash, height) do
    receipt = LiveReads.rpc!(context, "eth_getTransactionReceipt", [hash])
    finalized = LiveReads.rpc!(context, "eth_getBlockByNumber", ["finalized", false])
    true = LiveReads.same?(receipt["transactionHash"], hash) and receipt["status"] == "0x1"

    true =
      LiveReads.quantity(receipt["blockNumber"]) <=
        min(height, LiveReads.quantity(finalized["number"]))

    true = is_list(receipt["logs"]) and length(receipt["logs"]) <= 1000
    receipt
  end

  defp event!(receipt, name, hash) do
    spec = ABI.function("orchestratorV4", name)
    topic = ABI.hash(name <> "(" <> Enum.map_join(spec["inputs"], ",", &ABI.type_name/1) <> ")")

    [log] =
      Enum.filter(receipt["logs"], fn log ->
        LiveReads.same?(log["address"], ABI.address("orchestratorV4")) and
          match?([^topic, ^hash | _], log["topics"])
      end)

    %{spec: spec, log: log}
  end

  defp delivered?(receipt, recipient, amount) do
    topic = ABI.hash("Transfer(address,address,uint256)")

    Enum.any?(receipt["logs"], fn log ->
      case log do
        %{"topics" => [^topic, _, target], "data" => data, "address" => token} ->
          LiveReads.same?(token, ABI.address("usdc")) and
            LiveReads.same?("0x" <> String.slice(target, -40, 40), recipient) and
            ABI.unhex(data) == <<amount::256>>

        _ ->
          false
      end
    end)
  end

  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, value)
  defp key(operation), do: "onramp:" <> operation
end

defmodule Raxol.Payments.Ramp.Peer.Wallet do
  @moduledoc """
  Default maker wallet boundary using the existing Wallet.sign_hash/1 and
  on_confirm approval path. No key is loaded or retained here. Signatures and
  signed transactions exist only transiently; only a transaction hash and
  expected public transaction digests enter the provider-private mapping.
  """
  @behaviour Raxol.Payments.Ramp.Peer.MakerWallet
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Ramp.Peer.{ABI, LiveIO, LiveReads, Mapping}

  @impl true
  def validate(context, plan, terms) do
    context = Map.put(context, :maker_operation, plan.operation_ref)

    guarded(fn ->
      wallet = Map.fetch!(context, :wallet)
      true = LiveReads.same?(wallet.address(), context.user) and wallet.chain_id() == 8453
      true = plan.owner == context.user and plan.chain_id == 8453 and plan.value == 0
      true = DateTime.compare(plan.expires_at, LiveReads.now(context)) == :gt

      true = plan.amount == terms.amount and plan.review == Map.delete(terms, :action)
      mapping = Map.fetch!(plan, :mapping)

      expected = LiveIO.expected_plan!(context, terms.action, plan.review, mapping)
      true = Map.take(plan, Map.keys(expected)) == expected
      :ok
    end)
  end

  @impl true
  def request(context, operation, pending, plan) do
    context = Map.put(context, :maker_operation, operation)

    guarded(fn ->
      :global.trans({{__MODULE__, String.downcase(context.user)}, self()}, fn ->
        submit_once(context, operation, pending, plan)
      end)
    end)
  end

  defp submit_once(context, operation, pending, plan) do
    wallet = context.wallet
    true = LiveReads.same?(wallet.address(), context.user) and wallet.chain_id() == 8453
    true = DateTime.compare(plan.expires_at, LiveReads.now(context)) == :gt
    fields = unsigned!(context, plan)
    # A confirmation is required for every wallet action, regardless of budget threshold.
    approve = Map.fetch!(context, :on_confirm)

    :approve =
      approve.(
        Decimal.div(Decimal.new(plan.amount), Decimal.new(1_000_000)),
        "peer.xyz " <> Atom.to_string(plan.action) <> " " <> plan.to
      )

    true = DateTime.compare(plan.expires_at, LiveReads.now(context)) == :gt
    :ok = validate(context, plan, Map.put(plan.review, :action, plan.requested_action))
    nonce = Enum.at(fields, 1)
    :ok = Mapping.claim_nonce(context.maker_mapping, context.user, nonce, operation)
    digest = ExKeccak.hash_256(<<2>> <> rlp(fields))
    LiveReads.boundary!(context)
    signature = wallet.sign_hash(digest)

    if match?({:error, _}, signature),
      do: Mapping.release_nonce(context.maker_mapping, context.user, nonce, operation)

    {:ok, <<r::binary-size(32), s::binary-size(32), v>>} = signature
    parity = if v >= 27, do: v - 27, else: v
    true = parity in [0, 1]
    {:ok, public} = ExSecp256k1.recover(digest, r, s, parity)
    true = LiveReads.same?(EIP712.address_from_pubkey(public), context.user)
    raw = <<2>> <> rlp(fields ++ [parity, :binary.decode_unsigned(r), :binary.decode_unsigned(s)])
    hash = ABI.hash(raw)
    {:ok, mapping} = Mapping.fetch(context.maker_mapping, operation)

    :ok =
      Mapping.put(
        context.maker_mapping,
        operation,
        Map.merge(mapping, %{
          owner: context.user,
          pending_action_ref: pending,
          pending_resolved: false,
          pending_failed: false,
          pending_kind: plan.action,
          pending_tx_hash: hash,
          expected_to: plan.to,
          expected_input_hash: ABI.hash(ABI.unhex(plan.data))
        })
      )

    {reader, handle} = LiveReads.reader(context)
    LiveReads.boundary!(context)
    {:ok, submitted} = reader.broadcast(handle, 8453, ABI.hex(raw))
    true = LiveReads.same?(hash, submitted)
    :ok
  end

  defp unsigned!(context, plan) do
    8453 = context |> LiveReads.rpc!("eth_chainId", []) |> LiveReads.quantity()

    nonce =
      context
      |> LiveReads.rpc!("eth_getTransactionCount", [context.user, "pending"])
      |> LiveReads.quantity()

    gas_price = context |> LiveReads.rpc!("eth_gasPrice", []) |> LiveReads.quantity()
    priority = context |> LiveReads.rpc!("eth_maxPriorityFeePerGas", []) |> LiveReads.quantity()
    max_fee = gas_price * 2 + priority
    true = max_fee > 0 and max_fee <= Map.get(context, :maker_max_fee_per_gas, 100_000_000_000)

    gas =
      context
      |> LiveReads.rpc!("eth_estimateGas", [
        %{from: context.user, to: plan.to, data: plan.data, value: "0x0"}
      ])
      |> LiveReads.quantity()

    true = gas in 21_000..2_000_000
    # Successful simulation cannot replace explicit approval or final receipt reconciliation.
    LiveReads.rpc!(context, "eth_call", [
      %{from: context.user, to: plan.to, data: plan.data, value: "0x0"},
      "latest"
    ])

    [8453, nonce, priority, max_fee, gas, ABI.unhex(plan.to), 0, ABI.unhex(plan.data), []]
  end

  @doc false
  def rlp(values) when is_list(values) do
    encoded = values |> Enum.map(&rlp/1) |> IO.iodata_to_binary()
    prefix(encoded, 192, 247)
  end

  def rlp(0), do: rlp(<<>>)
  def rlp(n) when is_integer(n) and n > 0, do: rlp(:binary.encode_unsigned(n))
  def rlp(<<n>> = value) when n < 128, do: value
  def rlp(value) when is_binary(value), do: prefix(value, 128, 183)

  defp prefix(value, short, _long) when byte_size(value) <= 55,
    do: <<short + byte_size(value)>> <> value

  defp prefix(value, _short, long) do
    size = :binary.encode_unsigned(byte_size(value))
    <<long + byte_size(size)>> <> size <> value
  end

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :wallet_unavailable}
  catch
    _, _ -> {:error, :wallet_unavailable}
  end
end

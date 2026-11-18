defmodule Raxol.Payments.Ramp.Peer.LiveReads do
  @moduledoc "Pinned Base protocol and public-indexer maker reads. Any incoherence fails closed."
  alias Raxol.Payments.{ChainReader, Checkpoint}
  alias Raxol.Payments.ChainReader.JSONRPC
  alias Raxol.Payments.Ramp.Coherence
  alias Raxol.Payments.Ramp.Peer.{ABI, Indexer}

  @template """
  query MakerTemplate($method: String!, $currency: String!) {
    DepositPaymentMethod(where: {paymentMethodHash: {_ilike: $method}, active: {_eq: true}}, order_by: {depositIdOnContract: asc}, limit: 32) { depositId depositIdOnContract paymentMethodHash }
    MethodCurrency(where: {paymentMethodHash: {_ilike: $method}, currencyCode: {_ilike: $currency}}, order_by: {depositIdOnContract: asc}, limit: 32) { depositId depositIdOnContract }
  }
  """
  @deposit """
  query MakerDeposit($id: String!) {
    Deposit_by_pk(id: $id) { depositId chainId escrowAddress depositor token remainingDeposits outstandingIntentAmount totalAmountTaken totalWithdrawn blockNumber status }
    Intent(where: {depositId: {_eq: $id}}, limit: 1001) { intentHash amount status releasedAmount orchestratorAddress }
    DepositFundActivity(where: {depositId: {_eq: $id}}, limit: 1001) { activityType amount blockNumber }
  }
  """
  def reader(context),
    do:
      Map.get_lazy(context, :chain_reader, fn ->
        JSONRPC.new(chains: %{8453 => "https://mainnet.base.org"})
      end)

  def rpc!(context, method, args) do
    boundary!(context)
    {:ok, result} = ChainReader.request(reader(context), 8453, method, args)
    result
  end

  def boundary!(%{maker_operation: operation, checkpoint: checkpoint}) do
    {:ok, record} = Checkpoint.fetch(checkpoint, "peer_maker:" <> operation)
    :ok = Checkpoint.put(checkpoint, "peer_maker:" <> operation, record)
  end

  def boundary!(_), do: :ok

  defp query!(context, query, variables) do
    boundary!(context)
    Indexer.query(context.maker_indexer, query, variables)
  end

  def quantity("0x" <> hex) when byte_size(hex) in 1..64 do
    {number, ""} = Integer.parse(hex, 16)
    true = number >= 0
    number
  end

  def hex(number), do: "0x" <> Integer.to_string(number, 16)
  def now(context), do: Map.get(context, :now, &DateTime.utc_now/0).()

  def height!(context) do
    8453 = context |> rpc!("eth_chainId", []) |> quantity()
    head = context |> rpc!("eth_blockNumber", []) |> quantity()
    height = max(0, head - Map.get(context, :maker_confirmations, 2))
    block = rpc!(context, "eth_getBlockByNumber", [hex(height), false])
    ^height = quantity(block["number"])
    age = DateTime.to_unix(now(context)) - quantity(block["timestamp"])
    true = age in 0..30
    height
  end

  def read!(context, contract, name, args, height) do
    result =
      rpc!(context, "eth_call", [
        %{to: ABI.address(contract), data: ABI.call(contract, name, args)},
        hex(height)
      ])

    ABI.result(contract, name, result)
  end

  def erc20!(context, selector, arguments, height) do
    words =
      Enum.map(arguments, fn
        "0x" <> address -> String.pad_leading(String.downcase(address), 64, "0")
      end)

    result =
      rpc!(context, "eth_call", [
        %{to: ABI.address("usdc"), data: selector <> Enum.join(words)},
        hex(height)
      ])

    <<n::256>> = ABI.unhex(result)
    n
  end

  def terms!(context, intent, rail) do
    true = intent.direction == "offramp" and is_nil(intent.route) and is_nil(intent.region)
    true = intent.fiat["currency"] == "USD" and intent.fiat["decimals"] in [2, 6]
    true = same?(intent.recipient, context.user)

    true =
      same?(Coherence.address(intent.crypto), ABI.address("usdc")) and
        intent.crypto["chain_id"] == "eip155:8453"

    method = ABI.config()["rails"][rail]["paymentMethodHash"]
    true = is_binary(method)
    currency = ABI.config()["currencyHash"]
    height = height!(context)
    false = read!(context, "escrowV2", "paused", [], height)
    false = read!(context, "orchestratorV4", "paused", [], height)
    balance = erc20!(context, "0x70a08231", [context.user], height)

    {:ok, data} =
      query!(context, @template, %{
        method: String.downcase(method),
        currency: String.downcase(currency)
      })

    methods = bounded_list!(data["DepositPaymentMethod"], 32)
    currencies = bounded_list!(data["MethodCurrency"], 32)

    # Earliest matching protocol ID supplies a market observation and bounds.
    # The resulting deposit fixes the observed rate reviewed in the preview.
    candidate =
      methods
      |> Enum.filter(fn item ->
        item["depositId"] == composite(uint!(item["depositIdOnContract"])) and
          same?(item["paymentMethodHash"], method) and
          Enum.any?(currencies, &(&1["depositId"] == item["depositId"]))
      end)
      |> Enum.min_by(&uint!(&1["depositIdOnContract"]))

    id = uint!(candidate["depositIdOnContract"])
    deposit = read!(context, "escrowV2", "getDeposit", [id], height)
    true = same?(deposit["token"], ABI.address("usdc"))
    true = read!(context, "escrowV2", "getDepositPaymentMethodActive", [id, method], height)
    true = read!(context, "escrowV2", "getDepositCurrencyListed", [id, method, currency], height)
    rate = read!(context, "escrowV2", "getEffectiveRate", [id, method, currency], height)

    minimum = deposit["intentAmountRange"]["min"]
    maximum = min(deposit["intentAmountRange"]["max"], balance)
    true = rate > 0 and minimum > 0 and maximum >= minimum

    %{
      minimum: minimum,
      maximum: maximum,
      rate: rate,
      expires_at: DateTime.add(now(context), 20),
      rail: rail
    }
  end

  def deposit!(context, id, owner) do
    height = height!(context)
    {:ok, data} = query!(context, @deposit, %{id: composite(id)})
    index = data["Deposit_by_pk"]
    true = to_string(index["chainId"]) == "8453" and uint!(index["depositId"]) == id
    true = same?(index["escrowAddress"], ABI.address("escrowV2"))
    true = same?(index["depositor"], owner) and same?(index["token"], ABI.address("usdc"))
    true = uint!(index["blockNumber"]) <= height
    chain = read!(context, "escrowV2", "getDeposit", [id], height)
    closed = index["status"] in ["CLOSED", "WITHDRAWN"]
    true = index["status"] in ["ACTIVE", "CLOSED", "WITHDRAWN"]
    true = owner_match?(chain["depositor"], owner, closed)
    true = owner_match?(chain["token"], ABI.address("usdc"), closed)
    remaining = chain["remainingDeposits"]
    outstanding = chain["outstandingIntentAmount"]
    ^remaining = uint!(index["remainingDeposits"])
    ^outstanding = uint!(index["outstandingIntentAmount"])
    unmatched = liquidity!(context, id, chain, height)
    hashes = read!(context, "escrowV2", "getDepositIntentHashes", [id], height)
    intents = bounded_list!(data["Intent"], 1000)
    active = Enum.filter(intents, &(&1["status"] == "SIGNALED"))
    true = length(hashes) == length(active) and length(hashes) == MapSet.size(MapSet.new(hashes))

    true =
      MapSet.new(Enum.map(active, &String.downcase(&1["intentHash"]))) ==
        MapSet.new(Enum.map(hashes, &String.downcase/1))

    active_amount =
      Enum.reduce(active, 0, fn item, sum ->
        true = same?(item["orchestratorAddress"], ABI.address("orchestratorV4"))
        intent = read!(context, "orchestratorV4", "getIntent", [item["intentHash"]], height)
        true = same?(intent["escrow"], ABI.address("escrowV2")) and intent["depositId"] == id
        amount = uint!(item["amount"])
        ^amount = intent["amount"]
        sum + amount
      end)

    ^outstanding = active_amount

    filled =
      intents
      |> Enum.filter(&(&1["status"] == "FULFILLED"))
      |> Enum.reduce(0, &(uint!(&1["releasedAmount"]) + &2))

    activity = bounded_list!(data["DepositFundActivity"], 1000)

    withdrawn =
      activity
      |> Enum.filter(&(&1["activityType"] in ["WITHDRAWN", "CLOSED"]))
      |> Enum.reduce(0, fn item, sum ->
        true = uint!(item["blockNumber"]) <= height
        sum + uint!(item["amount"])
      end)

    ^filled = uint!(index["totalAmountTaken"])
    ^withdrawn = uint!(index["totalWithdrawn"])
    true = not closed or remaining + outstanding == 0

    %{
      state: :confirmed,
      deposit_id: to_string(id),
      order_id: composite(id),
      remaining: to_string(remaining + outstanding),
      unmatched: to_string(unmatched),
      filled: to_string(filled),
      withdrawn: to_string(withdrawn),
      active_intents: length(active)
    }
  end

  defp liquidity!(_context, _id, %{"remainingDeposits" => 0}, _height), do: 0

  defp liquidity!(context, id, chain, height) do
    viewer =
      read!(context, "protocolViewerV4", "getDeposit", [ABI.address("escrowV2"), id], height)

    ^id = viewer["depositId"]

    true =
      viewer["deposit"]["remainingDeposits"] == chain["remainingDeposits"] and
        viewer["deposit"]["outstandingIntentAmount"] == chain["outstandingIntentAmount"]

    true = viewer["availableLiquidity"] <= chain["remainingDeposits"]
    viewer["availableLiquidity"]
  end

  def same?(a, b) when is_binary(a) and is_binary(b), do: String.downcase(a) == String.downcase(b)
  def same?(_, _), do: false

  def uint!(v) when is_binary(v) and byte_size(v) in 1..78 do
    true = Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, v)
    n = String.to_integer(v)
    true = n < Integer.pow(2, 256)
    n
  end

  defp composite(id), do: "8453_" <> ABI.address("escrowV2") <> "_" <> to_string(id)
  defp bounded_list!(list, max) when is_list(list) and length(list) <= max, do: list

  defp owner_match?(actual, expected, closed),
    do: same?(actual, expected) or (closed and actual == "0x" <> String.duplicate("0", 40))
end

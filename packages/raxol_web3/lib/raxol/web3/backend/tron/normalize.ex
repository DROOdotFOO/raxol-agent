defmodule Raxol.Web3.Backend.Tron.Normalize do
  @moduledoc false
  # Internal to `Raxol.Web3.Backend.Tron`.
  #
  # Maps TronGrid, TronScan and SQD payloads onto the `Raxol.Web3.Backend`
  # shapes. Every account leaves here in Base58, however the upstream spelled
  # it, and an unreadable field is `nil` or a `{:decode_failed, _}`, never a
  # guess.

  import Raxol.Web3.Backend.Decode, only: [dig: 2, field: 2, int: 1, object: 1, rows_of: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Tron.Address

  @doc "A TronGrid `getTransactionById` body."
  @spec trongrid_transaction(term()) :: {:ok, Backend.transaction()} | {:error, Backend.error()}
  def trongrid_transaction(body) when is_map(body) do
    contract = contract_call(body)
    raw = body |> field("raw_data") |> object()

    with {:ok, value} <- Backend.money(contract["amount"] || contract["call_value"], :value) do
      {:ok,
       %{
         hash: body["txID"],
         status: contract_status(body),
         # `getTransactionInfoById` is the tool that carries a block and a fee,
         # and it currently refuses its own output. TronScan is the source that
         # answers those fields.
         block: nil,
         timestamp: epoch_ms(raw["timestamp"]),
         from: ref(contract["owner_address"]),
         to: ref(counterparty(contract)),
         value: value,
         fee: nil,
         method: contract_type(raw["contract"])
       }}
    end
  end

  def trongrid_transaction(_body), do: {:error, {:decode_failed, :transaction}}

  @doc "A row from TronGrid's account transaction list."
  @spec trongrid_list_transaction(term()) ::
          {:ok, Backend.transaction()} | {:error, Backend.error()}
  def trongrid_list_transaction(item) when is_map(item) do
    contract = contract_call(item)

    with {:ok, value} <- Backend.money(contract["amount"] || contract["call_value"], :value),
         {:ok, fee} <- Backend.money(ret_fee(item), :fee) do
      {:ok, trongrid_transaction_row(item, contract, value, fee)}
    end
  end

  def trongrid_list_transaction(_item), do: {:error, {:decode_failed, :transaction_row}}

  # A listed transaction answers its own block and its own fee, which is why
  # this row is wider than the one `trongrid_transaction/1` can build out of
  # `getTransactionById` alone.
  defp trongrid_transaction_row(item, contract, value, fee) do
    %{
      hash: item["txID"],
      status: contract_status(item),
      block: int(item["blockNumber"]),
      timestamp: epoch_ms(item["block_timestamp"]),
      from: ref(contract["owner_address"]),
      to: ref(counterparty(contract)),
      value: value,
      fee: fee,
      method: item |> field("raw_data") |> field("contract") |> contract_type()
    }
  end

  @doc "A TronScan transaction body."
  @spec tronscan_transaction(term()) :: {:ok, Backend.transaction()} | {:error, Backend.error()}
  def tronscan_transaction(body) when is_map(body) do
    with {:ok, fee} <- Backend.money(body |> field("cost") |> field("fee"), :fee) do
      {:ok,
       %{
         hash: body["hash"],
         status: ret_status(body["contractRet"]),
         block: int(body["block"]),
         timestamp: epoch_ms(body["timestamp"]),
         from: ref(body["ownerAddress"]),
         to: ref(body["toAddress"]),
         value: nil,
         fee: fee,
         method: method_name(body["contractType"])
       }}
    end
  end

  def tronscan_transaction(_body), do: {:error, {:decode_failed, :transaction}}

  @doc "A TronGrid `getBlock` body."
  @spec trongrid_block(term()) :: Backend.block()
  def trongrid_block(body) do
    raw = body |> field("block_header") |> field("raw_data") |> object()

    %{
      height: int(raw["number"]),
      hash: body["blockID"],
      timestamp: epoch_ms(raw["timestamp"]),
      transactions_count: body |> field("transactions") |> length_or_nil(),
      miner: ref(raw["witness_address"])
    }
  end

  @doc """
  Both standards out of one account record. TRC-20 arrives as a list of
  single-key maps from contract address to an amount string; TRC-10 as a list
  of `key`/`value` pairs whose key is the numeric asset id. Neither list is
  guaranteed by anything but the upstream's habit, so a row that is not the
  shape claimed fails the read rather than raising inside the walk: the
  router fails over on `{:decode_failed, _}`, and a `FunctionClauseError`
  here would abort the read and carry the row into its own message.

  An ABSENT list is empty rather than a failure, because an account holding
  one standard and not the other omits the key it has nothing for.
  """
  @spec trongrid_token_balances(term()) ::
          {:ok, [Backend.token_balance()]} | {:error, Backend.error()}
  def trongrid_token_balances(record) do
    with {:ok, trc20} <- trc20_pairs(field(record, "trc20")),
         {:ok, trc10} <- trc10_pairs(field(record, "assetV2")) do
      Backend.map_rows(trc20 ++ trc10, &token_balance_row/1, :token_balance_row)
    end
  end

  defp trc20_pairs(nil), do: {:ok, []}

  defp trc20_pairs(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      entry, {:ok, acc} when is_map(entry) ->
        {:cont, {:ok, Enum.reduce(entry, acc, &[{:trc20, elem(&1, 0), elem(&1, 1)} | &2])}}

      _row, {:ok, _acc} ->
        {:halt, {:error, {:decode_failed, :token_balance_row}}}
    end)
    |> reversed()
  end

  defp trc20_pairs(_other), do: {:error, {:decode_failed, :token_balances}}

  defp trc10_pairs(nil), do: {:ok, []}

  defp trc10_pairs(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{"key" => id, "value" => amount}, {:ok, acc} ->
        {:cont, {:ok, [{:trc10, id, amount} | acc]}}

      _row, {:ok, _acc} ->
        {:halt, {:error, {:decode_failed, :token_balance_row}}}
    end)
    |> reversed()
  end

  defp trc10_pairs(_other), do: {:error, {:decode_failed, :token_balances}}

  defp reversed({:ok, pairs}), do: {:ok, Enum.reverse(pairs)}
  defp reversed({:error, _reason} = error), do: error

  defp token_balance_row({:trc10, id, amount}) do
    with {:ok, parsed} <- Backend.money(amount, :amount) do
      {:ok, %{token: token(nil, "TRC-10"), amount: parsed, token_id: asset_id(id)}}
    end
  end

  defp token_balance_row({:trc20, contract, amount}) do
    with {:ok, parsed} <- Backend.money(amount, :amount) do
      {:ok, %{token: token(canonical(contract), "TRC-20"), amount: parsed, token_id: nil}}
    end
  end

  # A TRC-10 id is the key of a `key`/`value` pair, so it is whatever the
  # upstream put there. A binary or an integer is an asset id; anything else is
  # not one, and rendering it with `to_string/1` would either raise or put
  # upstream structure in the field a caller keys a token by.
  defp asset_id(id) when is_binary(id), do: id

  defp asset_id(id) when is_integer(id), do: Integer.to_string(id)
  defp asset_id(_other), do: nil

  @doc "A TronScan token-balance row."
  @spec tronscan_token_balance(term()) ::
          {:ok, Backend.token_balance()} | {:error, Backend.error()}
  def tronscan_token_balance(item) when is_map(item) do
    {address, token_id} = token_identity(item["tokenId"])

    with {:ok, amount} <- Backend.money(item["balance"], :amount) do
      {:ok,
       %{
         token: %{
           address: address,
           symbol: presence(item["tokenAbbr"]),
           name: presence(item["tokenName"]),
           decimals: int(item["tokenDecimal"]),
           type: token_type(item["tokenType"], item["tokenId"])
         },
         amount: amount,
         token_id: token_id
       }}
    end
  end

  def tronscan_token_balance(_item), do: {:error, {:decode_failed, :token_balance_row}}

  @doc "A TronGrid TRC-20 transfer row."
  @spec trongrid_token_transfer(term()) ::
          {:ok, Backend.token_transfer()} | {:error, Backend.error()}
  def trongrid_token_transfer(item) when is_map(item) do
    info = item |> field("token_info") |> object()

    with {:ok, amount} <- Backend.money(item["value"], :amount) do
      {:ok,
       %{
         token: %{
           address: canonical(info["address"]),
           symbol: presence(info["symbol"]),
           name: presence(info["name"]),
           decimals: int(info["decimals"]),
           type: "TRC-20"
         },
         amount: amount,
         from: ref(item["from"]),
         to: ref(item["to"]),
         block: nil,
         timestamp: epoch_ms(item["block_timestamp"]),
         transaction: item["transaction_id"]
       }}
    end
  end

  def trongrid_token_transfer(_item), do: {:error, {:decode_failed, :token_transfer_row}}

  @doc "A TronScan transfer-list row."
  @spec tronscan_token_transfer(term()) ::
          {:ok, Backend.token_transfer()} | {:error, Backend.error()}
  def tronscan_token_transfer(item) when is_map(item) do
    with {:ok, amount} <- Backend.money(item["amount"], :amount) do
      {:ok, tronscan_transfer_row(item, amount)}
    end
  end

  def tronscan_token_transfer(_item), do: {:error, {:decode_failed, :token_transfer_row}}

  defp tronscan_transfer_row(item, amount) do
    %{
      token: tronscan_transfer_token(item),
      amount: amount,
      from: ref(item["transferFromAddress"]),
      to: ref(item["transferToAddress"]),
      block: int(item["block"]),
      timestamp: epoch_ms(item["timestamp"]),
      transaction: item["transactionHash"]
    }
  end

  # A transfer describes the token it moves under `tokenInfo`, with the same
  # keys a balance row spells at its top level, so the identity split and the
  # symbol/name/decimals triple are read here rather than beside the fields
  # that belong to the transfer itself.
  defp tronscan_transfer_token(item) do
    info = item |> field("tokenInfo") |> object()
    {address, _token_id} = token_identity(info["tokenId"])

    %{
      address: address,
      symbol: presence(info["tokenAbbr"]),
      name: presence(info["tokenName"]),
      decimals: int(info["tokenDecimal"]),
      type: token_type(info["tokenType"], info["tokenId"])
    }
  end

  # The native asset has neither an address nor an asset id, a TRC-10 has an id
  # and no address, and a TRC-20 has an address and no id. One function so the
  # three cases cannot drift apart between the balance and the transfer mapper.
  defp token_identity("_"), do: {nil, nil}

  defp token_identity(id) when is_binary(id) do
    if numeric?(id), do: {nil, id}, else: {canonical(id), nil}
  end

  defp token_identity(_absent), do: {nil, nil}

  defp token_type(_upstream, "_"), do: "TRX"
  defp token_type("trc10", _id), do: "TRC-10"
  defp token_type("trc20", _id), do: "TRC-20"
  defp token_type("trc721", _id), do: "TRC-721"
  defp token_type("trc1155", _id), do: "TRC-1155"
  defp token_type(_other, _id), do: nil

  defp token(address, type) do
    %{address: address, symbol: nil, name: nil, decimals: nil, type: type}
  end

  defp contract_call(body) do
    body
    |> field("raw_data")
    |> field("contract")
    |> rows_of()
    |> List.first()
    |> field("parameter")
    |> field("value")
    |> object()
  end

  defp contract_type([%{"type" => type} | _rest]) when is_binary(type), do: type
  defp contract_type(_absent), do: nil

  # The recipient is named differently per contract type, and none of the three
  # is a fallback for the others: a transfer names `to_address`, a contract call
  # names the contract it calls, and a resource delegation names the receiver.
  defp counterparty(contract) do
    contract["to_address"] || contract["contract_address"] || contract["receiver_address"]
  end

  defp contract_status(body) do
    body |> field("ret") |> rows_of() |> List.first() |> field("contractRet") |> ret_status()
  end

  defp ret_status("SUCCESS"), do: :success
  defp ret_status(nil), do: :pending
  defp ret_status(_reverted), do: :reverted

  # The fee of a listed transaction lives in the same first `ret` entry that
  # carries the `contractRet` `contract_status/1` reads.
  defp ret_fee(item) do
    item |> field("ret") |> rows_of() |> List.first() |> field("fee")
  end

  @doc "The indexer shape from `portal_get_network_info`."
  @spec sqd_indexer(term()) :: Backend.indexer()
  def sqd_indexer(body) do
    indexing = body |> field("indexing") |> object()

    # `:indexed_ratio` is absent rather than computed: this upstream publishes
    # a lag in blocks and in seconds and no ratio at all, and a 1.0 here would
    # be a fabricated number in the one field that exists so lag is visible.
    %{finished?: body["real_time"] == true}
    |> put_measure(:lag_blocks, int(indexing["finalized_lag_blocks"]))
    |> put_measure(:lag_seconds, int(indexing["finalized_lag_seconds"]))
  end

  defp put_measure(indexer, _key, nil), do: indexer
  defp put_measure(indexer, key, value), do: Map.put(indexer, key, value)

  @doc "The height out of a block header."
  @spec block_number(term()) :: {:ok, integer()} | {:error, {:decode_failed, :block}}
  def block_number(body) do
    case int(dig(body, ["block_header", "raw_data", "number"])) do
      number when is_integer(number) -> {:ok, number}
      nil -> {:error, {:decode_failed, :block}}
    end
  end

  @doc "The height of the first row of a block page."
  @spec first_block_number(term()) ::
          {:ok, integer() | nil} | {:error, {:decode_failed, :blocks}}
  def first_block_number([%{"number" => number} | _rest]), do: {:ok, int(number)}
  def first_block_number(_rows), do: {:error, {:decode_failed, :blocks}}

  @doc """
  The irreversible view, from the flag the explorer publishes per block. A
  page with no confirmed row is `nil` rather than the head: the shape exists
  so a consumer can compute a confirmation depth, and reporting the head
  twice would make that depth zero.
  """
  @spec highest_confirmed([term()]) :: integer() | nil
  def highest_confirmed(rows) do
    rows
    |> Enum.filter(&(field(&1, "confirmed") == true))
    |> Enum.map(&int(field(&1, "number")))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  @doc "The `data` list of a TronScan page, or `{:decode_failed, tag}`."
  @spec rows(term(), atom()) :: {:ok, list()} | {:error, {:decode_failed, atom()}}
  def rows(%{"data" => rows}, _tag) when is_list(rows), do: {:ok, rows}
  def rows(_body, tag), do: {:error, {:decode_failed, tag}}

  @doc "The first row of a TronScan page; an empty page is `:not_found`."
  @spec first_row(term(), atom()) :: {:ok, map()} | {:error, Backend.error()}
  def first_row(body, tag) do
    case rows(body, tag) do
      {:ok, [row | _rest]} when is_map(row) -> {:ok, row}
      {:ok, _empty} -> {:error, {:upstream_refused, :not_found}}
      error -> error
    end
  end

  @doc "An integer at `path`, or `{:decode_failed, tag}`."
  @spec dig_int(term(), [String.t()], atom()) ::
          {:ok, integer()} | {:error, {:decode_failed, atom()}}
  def dig_int(body, path, tag) do
    case int(dig(body, path)) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:error, {:decode_failed, tag}}
    end
  end

  @doc """
  The one place either encoding is accepted, and the one place it collapses.
  Everything below holds Base58, so nothing downstream can key a cache, a
  cursor scope or a rate-limit spend on the spelling a caller happened to use.
  """
  @spec account(term()) :: {:ok, String.t()} | {:error, {:unsupported_account_ref, atom()}}
  def account({:tron, value}) when is_binary(value) do
    case Address.canonical(value) do
      {:ok, base58} -> {:ok, base58}
      {:error, :invalid_address} -> {:error, {:unsupported_account_ref, :tron}}
    end
  end

  def account({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  def account(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp ref(nil), do: nil

  defp ref(value) when is_binary(value) do
    case Address.canonical(value) do
      {:ok, base58} -> {:tron, base58}
      {:error, :invalid_address} -> nil
    end
  end

  defp ref(_other), do: nil

  defp canonical(nil), do: nil

  defp canonical(value) when is_binary(value) do
    case Address.canonical(value) do
      {:ok, base58} -> base58
      {:error, :invalid_address} -> nil
    end
  end

  defp canonical(_other), do: nil

  @doc """
  The address we asked about is the fallback, because a response that echoes
  nothing back still describes the account that was requested.
  """
  @spec canonical_or(term(), String.t()) :: String.t()
  def canonical_or(value, requested), do: canonical(value) || requested

  defp numeric?(value) when is_binary(value) do
    match?({_number, ""}, Integer.parse(value))
  end

  @doc "A non-empty binary, otherwise `nil`."
  @spec presence(term()) :: String.t() | nil
  def presence(nil), do: nil
  def presence(""), do: nil
  def presence(value) when is_binary(value), do: value
  def presence(_other), do: nil

  defp length_or_nil([]), do: nil
  defp length_or_nil(list) when is_list(list), do: length(list)
  defp length_or_nil(_other), do: nil

  @doc "Seconds as milliseconds, or `nil`."
  @spec seconds_to_ms(term()) :: number() | nil
  def seconds_to_ms(value) when is_number(value), do: value * 1000
  def seconds_to_ms(_other), do: nil

  defp epoch_ms(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp epoch_ms(_other), do: nil

  # `contractType` is an integer on this upstream, and `to_string/1` on
  # whatever else an upstream might put there raises rather than naming a
  # method. A shape this module does not read is no method name at all.
  defp method_name(value) when is_integer(value), do: Integer.to_string(value)

  defp method_name(value) when is_binary(value), do: presence(value)
  defp method_name(_other), do: nil
end

defmodule Raxol.Web3.Backend.JSONRPC do
  @moduledoc """
  The partial source: a backend whose upstream is a raw JSON-RPC node.

  ADR-0039 decision 4. A node has no index over accounts, so it cannot list what
  an address did or holds, but it serves `eth_call` and `eth_getLogs`, which a
  challenge-gated explorer cannot.

  ## Declared callbacks

  Required: `chain_info/1` and `block_height/1`. Declared: `get_transaction/2`,
  `account_info/2`, `get_block/2`, `get_logs/3`, `read_contract/2` and
  `raw_request/2`. Absent (and reported by `Raxol.Web3.Router.coverage/2`):
  `list_transactions/3`, `token_balances/2`, `list_token_transfers/3`,
  `list_nfts/3`, `contract_metadata/2` and `resolve_name/2`.

  ## `nil` fields

  `chain_info/1` answers `total_blocks`, `total_transactions` and
  `total_addresses` as `nil`, and `block_height/1` answers `indexer: nil`: those
  are an indexer's, and a node keeps none. `average_block_time_ms` is derived
  from two real block timestamps 100 blocks apart.

  ## Identity check

  `chain_info/1` compares `eth_chainId` with the handle's chain reference. A
  mismatch is `{:blocked, :chain_mismatch}`, terminal at the router so a
  misconfigured URL is not papered over by failover. Other callbacks do not
  repeat the check.

  ## `contract?`

  `account_info/2` reports code presence from `eth_getCode`. Since EIP-7702 a
  delegated wallet carries code, so this is not "is a contract".

  ## Transactions

  `get_transaction/2` reads the transaction and its receipt. In the pool but
  unmined is `:pending` with a `nil` block; an unknown hash is
  `{:error, {:upstream_refused, :not_found}}`, which the router does not fail
  over on. There is no timestamp, and `method` is the four-byte selector.

  ## Logs

  A `get_logs/3` request covers at most 2,000 blocks. The cursor carries the next
  `fromBlock` and the head pinned at the walk's start, so a walk terminates.

  ## Chains

  `@default_urls` has one dated entry (chain 4663); every other chain needs an
  explicit `:url`.
  """

  @behaviour Raxol.Web3.Backend

  import Raxol.Web3.Backend.Decode, only: [rows_of: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin
  alias Raxol.Web3.RPC
  alias Raxol.Web3.Scope

  # Probed 2026-09-14: this endpoint answered `eth_chainId` with `0x1237`, which
  # is 4663, and `eth_blockNumber` with `0x3bd25de`. A table entry is a claim
  # about a live endpoint on a date, so the table carries only what was probed.
  @default_urls %{
    4663 => "https://rpc.mainnet.chain.robinhood.com"
  }

  # A guess, labelled as one per ADR-0038's mitigation list: no node in
  # `@default_urls` publishes a rate limit. The floor is set by the most
  # expensive callback rather than by taste, which is what makes it a figure
  # rather than a number: `chain_info/1` costs three calls, so a capacity below
  # that would refuse its own read. A deployment with a real figure passes
  # `:rate_limit` inside `:http_opts` and this is never consulted.
  @rate_limit [capacity: 10, refill_per_second: 4.0]

  # Both judgements, neither measured.
  #
  # The block-time span is wide enough that one slow block does not dominate and
  # narrow enough to cost one extra round trip rather than a walk. The log
  # window is the per-request block range: small enough that a public node will
  # serve it, large enough that a walk over a day of blocks is tens of pages and
  # not thousands. The lookback is how far back a walk starts when the caller
  # gives no cursor.
  @block_time_sample 100
  @log_window 2_000
  @log_lookback 10_000

  # `0x` plus twenty bytes, either case. The same table and the same walk as
  # `Raxol.Web3.Backend.Blockscout`, because it is the same address shape.
  @hex_digits Enum.concat([?0..?9, ?a..?f, ?A..?F])

  # `:http_opts` is an operator's own keyword list and may carry an
  # authorization header, and `:url` often embeds a provider key, so neither is
  # something `inspect/1` may render: a handle reaches an operator through
  # `Raxol.Web3.Router.candidates/3`, and a crash anywhere below formats the
  # struct whole into a log line.
  @derive {Inspect, except: [:url, :http_opts]}
  @enforce_keys [:chain_ref, :chain_id, :url]
  defstruct [
    :chain_ref,
    :chain_id,
    :url,
    http_opts: [],
    cache?: true,
    log_window: @log_window,
    log_lookback: @log_lookback
  ]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          chain_id: non_neg_integer(),
          url: String.t(),
          http_opts: keyword(),
          cache?: boolean(),
          log_window: pos_integer(),
          log_lookback: pos_integer()
        }

  # `get_transaction/2` leads the list because it is the one that moved: it was
  # required until 2026-09-14, and it is declared here rather than assumed
  # because an archive with no index over transaction ids cannot answer it. A
  # node can. The three that follow the reads a node simply does not have.
  @capabilities [
    :get_transaction,
    :account_info,
    :get_block,
    :get_logs,
    :read_contract,
    :raw_request
  ]

  @doc """
  Build a handle for a CAIP-2 chain reference.

  `:url` is the node. Without one, `@default_urls` answers for a chain that was
  probed, and every other chain is `{:error, :no_rpc_url}` rather than a guess.

  `:http_opts` is forwarded to `Raxol.Web3.HTTP` unchanged, except that a
  `:rate_limit` the caller did not set is seeded with this module's labelled
  figure. `:cache` defaults to `true`; a height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, chain_id} <- chain_id(chain_ref),
         {:ok, url} <- url(chain_id, Keyword.get(opts, :url)) do
      state = %__MODULE__{
        chain_ref: chain_ref,
        chain_id: chain_id,
        url: url,
        http_opts: Keyword.put_new(Keyword.get(opts, :http_opts, []), :rate_limit, @rate_limit),
        cache?: Keyword.get(opts, :cache, true),
        log_window: Keyword.get(opts, :log_window, @log_window),
        log_lookback: Keyword.get(opts, :log_lookback, @log_lookback)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The dated chain-to-URL table. Data, not behaviour."
  @spec default_urls() :: %{non_neg_integer() => String.t()}
  def default_urls, do: @default_urls

  @impl Backend
  def backend, do: :jsonrpc

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{}), do: @capabilities

  # The key `Raxol.Web3.HTTP` writes on every request to this node, so a router
  # ordering by it reads the verdict the outbound path already recorded.
  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with :ok <- check_chain_id(state),
         {:ok, latest} <- head_block(state),
         {:ok, average} <- average_block_time_ms(state, latest) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: average,
         # A node keeps no aggregate counters. `nil` is what it knows.
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    with {:ok, height} <- RPC.block_number(state.url, state.http_opts),
         {:ok, finalized} <- RPC.block_height_by_tag(state.url, "finalized", state.http_opts) do
      # Never cached, and `indexer: nil` because there is no indexer here.
      {:ok, %{height: height, finalized_height: finalized, unit: :block, indexer: nil}}
    end
  end

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) when is_binary(hash) do
    case RPC.transaction(state.url, hash, rpc_opts(state, {:transaction, hash}, :transaction)) do
      {:ok, nil} -> {:error, {:upstream_refused, :not_found}}
      {:ok, transaction} -> with_receipt(state, hash, transaction)
      {:error, _reason} = error -> error
    end
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, balance} <- RPC.balance(state.url, address, "latest", account_opts(state, address)),
         {:ok, code} <- RPC.code(state.url, address, "latest", code_opts(state, address)) do
      {:ok,
       %{
         ref: {:evm, address},
         balance: balance,
         # Code presence, not account type. See the moduledoc: EIP-7702.
         # `Raxol.Web3.RPC.code/4` refuses a non-binary result as
         # `{:decode_failed, :code}`, so there is no nil to test for here.
         contract?: code != "0x",
         # A node has no source, so it can verify nothing and knows no names.
         verified?: false,
         name: nil,
         ens: nil
       }}
    end
  end

  @impl Backend
  def get_block(%__MODULE__{} = state, number_or_hash) do
    case fetch_block(state, number_or_hash) do
      {:ok, nil} -> {:error, {:upstream_refused, :not_found}}
      {:ok, body} -> block(body)
      {:error, _reason} = error -> error
    end
  end

  @impl Backend
  def get_logs(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, window} <- window(state, Keyword.get(opts, :cursor)),
         {:ok, items} <- log_rows(state, address, window) do
      {:ok, %{items: items, next: next_cursor(state, window)}}
    end
  end

  @impl Backend
  def read_contract(%__MODULE__{} = state, %{to: _to, data: _data} = call) do
    # Uncached, like the REST backend's: a gate reading a balance through
    # `eth_call` is the caller least able to accept a stale answer.
    RPC.eth_call(state.url, call, Map.get(call, :block, "latest"), state.http_opts)
  end

  @doc """
  A JSON-RPC call for a method on `Raxol.Web3.RPC`'s compile-time allowlist.

  This is the callback ADR-0033 section 3 introduced the allowlist for, and this
  backend is its intended use: an unbounded passthrough to a node reaches
  `eth_sendRawTransaction`. `Raxol.Web3.RPC.call/4` refuses a method outside the
  allowlist before a request is built, so the refusal costs no outbound call.

  Nothing on the served surface takes a method name from a caller, so this is
  reachable from Elixir and from nowhere else.
  """
  @impl Backend
  def raw_request(%__MODULE__{} = state, %{method: method} = request) when is_binary(method) do
    RPC.call(state.url, method, Map.get(request, :params, []), state.http_opts)
  end

  def raw_request(%__MODULE__{}, _malformed), do: {:error, {:unsupported, :rpc_method}}

  # One place composes a cache class onto an RPC call, as the REST backend's
  # `get/4` does for a path. The key fragment is the method and its own
  # arguments, never the URL: a bring-your-own-node deployment carries its
  # credential in the host or the path, and ADR-0033 section 7 names cache keys
  # as one of the four places a credential leaks. The fragment sits under the
  # handle's scope, and `Raxol.Web3.HTTP` adds the origin id.
  defp rpc_opts(state, fragment, class) do
    Cache.opts(state.http_opts, scope(state), state.cache?, fragment, class)
  end

  # Both halves of an account read share the `:account` class. Code gets the
  # short TTL rather than `:contract_metadata`'s hour for one reason: an
  # EIP-7702 delegation can appear and disappear between two transactions, so an
  # hour-old `contract?` is a stale answer to a question that moves.
  defp account_opts(state, address), do: rpc_opts(state, {:balance, address}, :account)
  defp code_opts(state, address), do: rpc_opts(state, {:code, address}, :account)

  defp logs_opts(state, address, %{from: from, to: to}) do
    rpc_opts(state, {:logs, address, from, to}, :list)
  end

  defp block_at(state, tag_or_number) do
    RPC.block_by_number(state.url, tag_or_number, block_opts(state, tag_or_number))
  end

  # A node with no head is a node that cannot answer anything, so `null` here is
  # a body that did not say what it claimed rather than a fact about a chain.
  defp head_block(state) do
    case block_at(state, "latest") do
      {:ok, nil} -> {:error, {:decode_failed, :block}}
      other -> other
    end
  end

  # A tag moves, a number does not, and only the second is worth a block TTL.
  defp block_opts(state, tag) when is_binary(tag), do: rpc_opts(state, nil, nil)
  defp block_opts(state, number), do: rpc_opts(state, {:block, number}, :block)

  defp fetch_block(state, number) when is_integer(number), do: block_at(state, number)

  defp fetch_block(state, "0x" <> rest = hash) when byte_size(rest) == 64 do
    RPC.block_by_hash(state.url, hash, rpc_opts(state, {:block, hash}, :block))
  end

  defp fetch_block(state, tag) when is_binary(tag), do: block_at(state, tag)

  defp with_receipt(state, hash, transaction) do
    with {:ok, receipt} <-
           RPC.receipt(state.url, hash, rpc_opts(state, {:receipt, hash}, :transaction)) do
      {:ok, transaction(transaction, receipt)}
    end
  end

  defp check_chain_id(%__MODULE__{chain_id: expected} = state) do
    with {:ok, hex} <-
           RPC.call(state.url, "eth_chainId", [], rpc_opts(state, :chain_id, :chain_stats)),
         {:ok, answered} <- RPC.decode_quantity(hex) do
      if answered == expected, do: :ok, else: {:error, {:blocked, :chain_mismatch}}
    end
  end

  # Advisory, like the REST backend's indexer lag: the block time is extra
  # information about a chain, not the chain's identity, so a node that has
  # pruned the earlier block or a chain younger than the sample answers `nil`
  # rather than failing the read. The head that this is derived from is not
  # advisory, and its failure is already `chain_info/1`'s failure.
  defp average_block_time_ms(state, latest) do
    with {:ok, height} <- RPC.decode_quantity(latest["number"]),
         true <- height > @block_time_sample,
         {:ok, newer} <- RPC.decode_quantity(latest["timestamp"]),
         {:ok, %{"timestamp" => hex}} <- block_at(state, height - @block_time_sample),
         {:ok, older} <- RPC.decode_quantity(hex) do
      {:ok, (newer - older) * 1000 / @block_time_sample}
    else
      _unavailable -> {:ok, nil}
    end
  end

  # Page one establishes the head and pins the walk to it. Every later page
  # takes both numbers from the cursor, so the walk terminates: a walk that
  # re-read the head each page would chase a chain that keeps producing blocks.
  defp window(state, nil) do
    with {:ok, head} <- RPC.block_number(state.url, state.http_opts) do
      {:ok, bounded(state, max(head - state.log_lookback + 1, 0), head)}
    end
  end

  defp window(state, cursor) do
    case Cursor.decode(cursor, scope(state), :rpc_logs) do
      {:ok, %{"from_block" => from, "to_block" => to}}
      when is_integer(from) and is_integer(to) ->
        {:ok, bounded(state, from, to)}

      {:ok, _incomplete} ->
        {:error, {:invalid_cursor, :malformed}}

      {:error, reason} ->
        {:error, {:invalid_cursor, reason}}
    end
  end

  defp bounded(state, from, walk_to) do
    %{from: from, to: min(from + state.log_window - 1, walk_to), walk_to: walk_to}
  end

  defp filter(address, %{from: from, to: to}) do
    %{
      "address" => address,
      "fromBlock" => RPC.encode_quantity(from),
      "toBlock" => RPC.encode_quantity(to)
    }
  end

  # One window's rows. The filter and the cache class are derived from the same
  # window, so the fetch and the row mapping stay together and `get_logs/3`
  # reads one `{:ok, items}` per page.
  defp log_rows(state, address, window) do
    with {:ok, logs} <-
           RPC.logs(state.url, filter(address, window), logs_opts(state, address, window)) do
      Backend.map_rows(logs, &log/1, :log_row)
    end
  end

  defp origin_id(state), do: Origin.for_url(state.url)

  defp scope(state), do: Scope.of(state.url, state.http_opts)

  defp next_cursor(_state, %{to: to, walk_to: walk_to}) when to >= walk_to, do: nil

  defp next_cursor(state, %{to: to, walk_to: walk_to}) do
    Cursor.encode(
      %{"from_block" => to + 1, "to_block" => walk_to},
      scope(state),
      :rpc_logs
    )
  end

  defp transaction(item, receipt) do
    %{
      hash: item["hash"],
      status: status(receipt),
      block: quantity(item["blockNumber"]),
      # A node's transaction record carries no timestamp. See the moduledoc.
      timestamp: nil,
      from: address_ref(item["from"]),
      to: address_ref(item["to"]),
      value: quantity(item["value"]),
      fee: fee(receipt),
      method: selector(item["input"])
    }
  end

  defp block(body) do
    with {:ok, height} <- RPC.decode_quantity(body["number"]) do
      {:ok,
       %{
         height: height,
         hash: body["hash"],
         timestamp: timestamp(body["timestamp"]),
         # A node that put something other than a list where the transaction
         # list belongs is a body that is not what it claimed, and `length/1`
         # on it raises rather than failing over.
         transactions_count: body |> Map.get("transactions") |> count(),
         miner: address_ref(body["miner"])
       }}
    end
  end

  defp count(list) when is_list(list), do: length(list)
  defp count(_other), do: nil

  defp log(item) when is_map(item) do
    {:ok,
     %{
       address: item["address"],
       topics: item |> Map.get("topics") |> rows_of() |> Enum.reject(&is_nil/1),
       data: item["data"],
       block: quantity(item["blockNumber"]),
       transaction: item["transactionHash"],
       index: quantity(item["logIndex"])
     }}
  end

  defp log(_item), do: {:error, {:decode_failed, :log_row}}

  # No receipt is a transaction the node holds but has not mined, which the
  # contract calls `:pending`. A mined receipt with no `status` field is
  # pre-Byzantium: none of the chains in `@default_urls` is, and `:pending` is
  # the only non-committal value the contract carries, with a non-nil `block`
  # to tell the two apart.
  defp status(nil), do: :pending
  defp status(%{"status" => "0x1"}), do: :success
  defp status(%{"status" => "0x0"}), do: :reverted
  defp status(_pre_byzantium), do: :pending

  defp fee(nil), do: nil

  defp fee(receipt) do
    with used when is_integer(used) <- quantity(receipt["gasUsed"]),
         price when is_integer(price) <- quantity(receipt["effectiveGasPrice"]) do
      used * price
    else
      _incomplete -> nil
    end
  end

  # The four-byte selector, because a node has no ABI to name it.
  defp selector("0x" <> rest) when byte_size(rest) >= 8, do: "0x" <> binary_part(rest, 0, 8)
  defp selector(_absent), do: nil

  defp address_ref(address) when is_binary(address), do: {:evm, address}
  defp address_ref(_absent), do: nil

  defp quantity(value) do
    case RPC.decode_quantity(value) do
      {:ok, number} -> number
      {:error, _reason} -> nil
    end
  end

  defp timestamp(value) do
    with {:ok, seconds} <- RPC.decode_quantity(value),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      datetime
    else
      _unusable -> nil
    end
  end

  defp chain_id("eip155:" <> id) do
    case Integer.parse(id) do
      {chain_id, ""} -> {:ok, chain_id}
      _unparseable -> {:error, {:unsupported_chain, id}}
    end
  end

  defp chain_id(other), do: {:error, {:unsupported_chain, other}}

  defp url(_chain_id, url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> {:ok, url}
      _unusable -> {:error, :invalid_rpc_url}
    end
  end

  defp url(chain_id, nil) do
    case Map.fetch(@default_urls, chain_id) do
      {:ok, url} -> {:ok, url}
      :error -> {:error, :no_rpc_url}
    end
  end

  # The one place a caller's account reference becomes a JSON-RPC parameter,
  # so the FORMAT is checked here rather than at the tool boundary: validation
  # sits on the function that performs the side effect.
  # `Raxol.Web3.Serialize.account_ref/1` builds `{:evm, value}` out of
  # anything a tool argument prefixes with `"evm:"`, and `Jason.encode!/1`
  # RAISES on a binary that is not valid UTF-8, so an address-shaped check is
  # what keeps a tool argument from crashing the read. Case is carried through
  # rather than normalized: an EIP-55 checksum is the caller's own typo
  # protection. `Raxol.Web3.Backend.Blockscout` checks the same shape.
  defp evm_address({:evm, address}) when is_binary(address) do
    if evm_address?(address),
      do: {:ok, address},
      else: {:error, {:unsupported_account_ref, :not_an_address}}
  end

  defp evm_address({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp evm_address(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp evm_address?("0x" <> hex) when byte_size(hex) == 40 do
    hex |> :binary.bin_to_list() |> Enum.all?(&(&1 in @hex_digits))
  end

  defp evm_address?(_other), do: false
end

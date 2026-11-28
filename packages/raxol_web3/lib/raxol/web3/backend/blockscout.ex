defmodule Raxol.Web3.Backend.Blockscout do
  @moduledoc """
  The EVM backend, against a Blockscout instance's `/api/v2/*` surface.

  ADR-0038 decision 7. The vendor publishes no spec for this surface, so the
  mapping is probe-derived, pinned by recorded responses in
  `test/fixtures/blockscout`, and must be re-probed on upgrade. It consumes the
  public REST API; the server is not forked (its licence forbids derivatives).

  ## Read-only and one-source heights

  `raw_request/2` is not implemented: a REST backend has no method parameter to
  abuse, so declining it keeps the backend read-only by construction.

  `block_height/1` never mixes sources. With an RPC URL configured both numbers
  come from the node (`eth_blockNumber`, `eth_getBlockByNumber("finalized")`);
  without one the height comes from REST and `finalized_height` is `nil`. A REST
  height with RPC finality could put `finalized_height` above `height`. Indexer
  lag is reported from `/api/v2/main-page/indexing-status`.

  ## Chains

  Final hosts only, since redirects are refused (`optimism.blockscout.com` 301s
  to `explorer.optimism.io`, so the table carries the latter). Chain 4663 is
  marked `challenge_gated`: its API answers 403 `cf-mitigated: challenge`, so
  the breaker trips and the router fails over to raw RPC until the rule lifts.

  ## `contract?`

  `account_info/2` passes `is_contract` through: code presence, which since
  EIP-7702 includes delegated wallets (the `vitalik.eth` fixture is
  `is_contract: true`).

  ## Token balances

  `token_balances/2` reads the paginated `/api/v2/addresses/{hash}/tokens`, not
  `/token-balances`, which is unpaginated and ran to 3 MB for one wallet.
  """

  @behaviour Raxol.Web3.Backend

  import Raxol.Web3.Backend.Decode,
    only: [field: 2, iso8601: 1, object: 1, ok_or: 2, page_rows: 1, rows_of: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.Backend.Decode
  alias Raxol.Web3.Backend.Paging
  alias Raxol.Web3.Backend.PathSegment
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.RPC
  alias Raxol.Web3.Scope

  # `:http_opts` is an operator's own keyword list and may carry an
  # authorization header, and `:rpc_url` often embeds a provider key, so
  # neither is something `inspect/1` may render: a handle reaches an operator
  # through `Raxol.Web3.Router.candidates/3`, and a crash anywhere below formats
  # the struct whole into a log line.
  # `:host` stays visible: it comes from the fixed table of public explorers
  # below, never from configuration.
  @derive {Inspect, except: [:rpc_url, :http_opts]}
  @enforce_keys [:chain_ref, :host]
  defstruct [:chain_ref, :host, :rpc_url, http_opts: [], cache?: true]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          host: String.t(),
          rpc_url: String.t() | nil,
          http_opts: keyword(),
          cache?: boolean()
        }

  # Probed 2026-09-13. `:serving` and `:challenge_gated` are both admitted; the
  # status is a dated note for a human, not a gate, because the breaker is what
  # decides reachability at runtime.
  @hosts %{
    1 => {"eth.blockscout.com", :serving},
    10 => {"explorer.optimism.io", :serving},
    137 => {"polygon.blockscout.com", :serving},
    8453 => {"base.blockscout.com", :serving},
    42_161 => {"arbitrum.blockscout.com", :serving},
    4663 => {"robinhoodchain.blockscout.com", :challenge_gated}
  }

  # Every optional callback this handle answers over REST alone. The four reads
  # about a thing on the chain lead the list because they were required until
  # ADR-0039: an explorer has the indexes they need, over accounts and over
  # transaction ids alike, so a Blockscout handle declares all four and nothing
  # that was answerable before that amendment stopped being answerable.
  @optional_with_rest [
    :get_transaction,
    :account_info,
    :list_transactions,
    :token_balances,
    :get_block,
    :list_token_transfers,
    :contract_metadata,
    :get_logs,
    :resolve_name,
    :list_nfts
  ]

  @hex_digits Enum.concat([?0..?9, ?a..?f, ?A..?F])

  @doc """
  Build a handle for a CAIP-2 chain reference.

  `:rpc_url` unlocks `read_contract/2` and the finalized half of
  `block_height/1`; without it both degrade honestly rather than guessing.
  `:http_opts` is forwarded to `Raxol.Web3.HTTP` unchanged.

  `:cache` defaults to `true`. Setting it to `false` turns off the response
  cache for this handle, which a caller that must see the head on every read
  needs and which nothing else can express: the TTLs in `Raxol.Web3.TTL` are
  short, but "short" is not "none". A height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, chain_id} <- chain_id(chain_ref),
         {:ok, {host, _status}} <-
           Map.fetch(@hosts, chain_id) |> ok_or({:unsupported_chain, chain_ref}) do
      state = %__MODULE__{
        chain_ref: chain_ref,
        host: host,
        rpc_url: Keyword.get(opts, :rpc_url),
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The chain-to-host table, with its dated status. Data, not behaviour."
  @spec hosts() :: %{non_neg_integer() => {String.t(), :serving | :challenge_gated}}
  def hosts, do: @hosts

  @impl Backend
  def backend, do: :blockscout

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{rpc_url: nil}), do: @optional_with_rest
  def capabilities(%__MODULE__{}), do: [:read_contract | @optional_with_rest]

  # The same key `Raxol.Web3.HTTP` writes on every request through this host,
  # so a router ordering by it sees the verdict the outbound path already
  # recorded rather than keeping a second opinion. `origin_id/1` registers the
  # origin as a side effect, which is what makes the key resolvable back to a
  # host by an operator.
  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  @impl Backend
  def cursor_scopes(%__MODULE__{} = state), do: [scope(state)]

  defp origin_id(state), do: Origin.for_url("https://#{state.host}/")

  # The REST base is the chain's host and nothing else, so the scope is too.
  defp scope(state), do: Scope.of("https://#{state.host}/", state.http_opts)

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with {:ok, body} <- get(state, "/api/v2/stats", %{}, :chain_stats),
         {:ok, blocks} <- Backend.int(body["total_blocks"], :total_blocks),
         {:ok, transactions} <- Backend.int(body["total_transactions"], :total_transactions),
         {:ok, addresses} <- Backend.int(body["total_addresses"], :total_addresses) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: body["average_block_time"],
         # A count of indexed blocks, not a height. Reading it as one is the
         # mistake ADR-0038 records: use `block_height/1`.
         total_blocks: blocks,
         total_transactions: transactions,
         total_addresses: addresses
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{rpc_url: nil} = state) do
    with {:ok, body} <- get(state, "/api/v2/blocks", %{"type" => "block"}),
         {:ok, height} <- latest_height(body) do
      {:ok, %{height: height, finalized_height: nil, unit: :block, indexer: indexer(state)}}
    end
  end

  def block_height(%__MODULE__{rpc_url: url} = state) do
    with {:ok, height} <- RPC.block_number(url, state.http_opts),
         {:ok, finalized} <- RPC.block_height_by_tag(url, "finalized", state.http_opts) do
      {:ok, %{height: height, finalized_height: finalized, unit: :block, indexer: indexer(state)}}
    end
  end

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) when is_binary(hash) do
    with {:ok, segment} <- PathSegment.encode(hash, "hash"),
         {:ok, body} <- get(state, "/api/v2/transactions/#{segment}", %{}, :transaction) do
      transaction(body)
    end
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, body} <- get(state, "/api/v2/addresses/#{segment(address)}", %{}, :account),
         {:ok, balance} <- Backend.money(body["coin_balance"], :balance) do
      {:ok,
       %{
         ref: {:evm, body["hash"] || address},
         balance: balance,
         contract?: body["is_contract"] == true,
         verified?: body["is_verified"] == true,
         name: body["name"],
         ens: body["ens_domain_name"]
       }}
    end
  end

  @impl Backend
  def list_transactions(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(
        state,
        "/api/v2/addresses/#{segment(address)}/transactions",
        :address_transactions,
        opts,
        &transaction/1
      )
    end
  end

  # The cursor this minted was unusable until 2026-09-14: the callback took no
  # `list_opts`, so `/tokens` handed back a `next` that no caller could feed in.
  @impl Backend
  def token_balances(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(
        state,
        "/api/v2/addresses/#{segment(address)}/tokens",
        :address_tokens,
        opts,
        &token_balance/1
      )
    end
  end

  @impl Backend
  def get_block(%__MODULE__{} = state, number) do
    with {:ok, segment} <- PathSegment.encode(number, "block"),
         {:ok, body} <- get(state, "/api/v2/blocks/#{segment}", %{}, :block),
         {:ok, height} <- Backend.int(body["height"], :height),
         {:ok, count} <- Backend.int(body["transactions_count"], :transactions_count) do
      {:ok,
       %{
         height: height,
         hash: body["hash"],
         timestamp: iso8601(body["timestamp"]),
         transactions_count: count,
         miner: address_ref(body["miner"])
       }}
    end
  end

  @impl Backend
  def list_token_transfers(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(
        state,
        "/api/v2/addresses/#{segment(address)}/token-transfers",
        :address_token_transfers,
        opts,
        &token_transfer/1
      )
    end
  end

  @impl Backend
  def get_logs(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(state, "/api/v2/addresses/#{segment(address)}/logs", :address_logs, opts, &log/1)
    end
  end

  @impl Backend
  def list_nfts(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, address} <- evm_address(account_ref) do
      page(state, "/api/v2/addresses/#{segment(address)}/nft", :address_nft, opts, &nft/1)
    end
  end

  @impl Backend
  def contract_metadata(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- evm_address(account_ref),
         {:ok, body} <-
           get(state, "/api/v2/smart-contracts/#{segment(address)}", %{}, :contract_metadata) do
      {:ok,
       %{
         name: body["name"],
         verified?: body["is_verified"] == true,
         language: body["language"],
         compiler_version: body["compiler_version"],
         abi: body["abi"],
         proxy_type: body["proxy_type"]
       }}
    end
  end

  @impl Backend
  def resolve_name(%__MODULE__{} = state, name) when is_binary(name) do
    with {:ok, body} <- get(state, "/api/v2/search", %{"q" => name}, :account),
         {:ok, rows} <- page_rows(body["items"]) do
      case Enum.find_value(rows, &match_name(&1, name)) do
        nil -> {:error, {:upstream_refused, :not_found}}
        ref -> {:ok, ref}
      end
    end
  end

  @impl Backend
  def read_contract(%__MODULE__{rpc_url: nil}, _call),
    do: {:error, {:unsupported, :read_contract}}

  def read_contract(%__MODULE__{rpc_url: url} = state, %{to: _to, data: _data} = call) do
    RPC.eth_call(url, call, Map.get(call, :block, "latest"), state.http_opts)
  end

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is built here, from the endpoint's own path and
  # its own query map, and never from the assembled URI: that is what keeps a
  # credential-bearing query parameter out of a cache key by construction
  # rather than by review. It sits under the handle's scope, and
  # `Raxol.Web3.HTTP` adds the origin id.
  defp get(state, path, query \\ %{}, class \\ nil) do
    state
    |> url(path, query)
    |> HTTP.get(Cache.opts(state.http_opts, scope(state), state.cache?, {path, query}, class))
    |> Decode.json_object()
  end

  defp url(state, path, query) when map_size(query) == 0, do: "https://#{state.host}#{path}"

  defp url(state, path, query) do
    "https://#{state.host}#{path}?#{URI.encode_query(query)}"
  end

  # For an address `evm_address/1` has already validated: encoding it is
  # defence in depth, not the check.
  defp segment(address) when is_binary(address), do: URI.encode(address, &URI.char_unreserved?/1)

  # Every list shares the `:list` class, and the cursor's decoded parameters are
  # part of the key: page two of a walk is a different cache entry from page
  # one, which is the only way a cached page and a cursor can coexist without
  # one serving the other's contents.
  defp page(state, path, endpoint, opts, mapper) do
    with {:ok, query} <-
           Paging.cursor_params(Keyword.get(opts, :cursor), scope(state), endpoint),
         {:ok, body} <- get(state, path, query, :list),
         {:ok, rows} <- page_rows(body["items"]),
         {:ok, items} <- Backend.map_rows(rows, mapper, endpoint) do
      {:ok,
       %{
         items: items,
         next: Paging.next_cursor(body["next_page_params"], scope(state), endpoint)
       }}
    end
  end

  defp transaction(item) when is_map(item) do
    fee = item |> field("fee") |> object()

    with {:ok, value} <- Backend.money(item["value"], :value),
         {:ok, paid} <- Backend.money(fee["value"], :fee),
         {:ok, block} <- Backend.int(item["block_number"], :block_number) do
      {:ok, normalized_transaction(item, value, paid, block)}
    end
  end

  defp transaction(_item), do: {:error, {:decode_failed, :transaction}}

  defp normalized_transaction(item, value, paid, block) do
    %{
      hash: item["hash"],
      status: status(item["status"]),
      block: block,
      timestamp: iso8601(item["timestamp"]),
      from: address_ref(item["from"]),
      to: address_ref(item["to"]),
      value: value,
      fee: paid,
      method: item["method"]
    }
  end

  defp token_balance(item) when is_map(item) do
    with {:ok, amount} <- Backend.money(item["value"], :amount),
         {:ok, token} <- token(item["token"]) do
      {:ok, %{token: token, amount: amount, token_id: item["token_id"]}}
    end
  end

  defp token_balance(_item), do: {:error, {:decode_failed, :token_balance_row}}

  defp token_transfer(item) when is_map(item) do
    total = item |> field("total") |> object()

    with {:ok, amount} <- Backend.money(total["value"], :amount),
         {:ok, token} <- token(item["token"]),
         {:ok, block} <- Backend.int(item["block_number"], :block_number) do
      {:ok,
       %{
         token: token,
         amount: amount,
         from: address_ref(item["from"]),
         to: address_ref(item["to"]),
         block: block,
         timestamp: iso8601(item["timestamp"]),
         transaction: item["transaction_hash"]
       }}
    end
  end

  defp token_transfer(_item), do: {:error, {:decode_failed, :token_transfer_row}}

  defp log(item) when is_map(item) do
    with {:ok, block} <- Backend.int(item["block_number"], :block_number),
         {:ok, index} <- Backend.int(item["index"], :index) do
      {:ok,
       %{
         address: item |> field("address") |> field("hash"),
         topics: item |> field("topics") |> rows_of() |> Enum.reject(&is_nil/1),
         data: item["data"],
         block: block,
         transaction: item["transaction_hash"],
         index: index
       }}
    end
  end

  defp log(_item), do: {:error, {:decode_failed, :log_row}}

  defp nft(item) when is_map(item) do
    with {:ok, token} <- token(item["token"]) do
      {:ok,
       %{
         token: token,
         token_id: item["id"],
         name: item |> field("metadata") |> field("name"),
         image_url: item["image_url"]
       }}
    end
  end

  defp nft(_item), do: {:error, {:decode_failed, :nft_row}}

  # `decimals` is the one field here that silently rewrites an amount: a
  # caller renders `amount / 10 ** decimals`, so a token declaring "18abc"
  # read as 18 would have been luck and read as 1 is a 10^17 error in what a
  # user is shown. It fails the row like any other unreadable field.
  defp token(token) when is_map(token) do
    with {:ok, decimals} <- Backend.int(token["decimals"], :decimals) do
      {:ok,
       %{
         address: token["address_hash"] || token["address"],
         symbol: token["symbol"],
         name: token["name"],
         decimals: decimals,
         type: token["type"]
       }}
    end
  end

  defp token(_absent),
    do: {:ok, %{address: nil, symbol: nil, name: nil, decimals: nil, type: nil}}

  defp match_name(%{"ens_info" => %{"name" => name}, "address_hash" => hash}, name)
       when is_binary(hash),
       do: {:evm, hash}

  defp match_name(_item, _name), do: nil

  defp address_ref(%{"hash" => hash}) when is_binary(hash), do: {:evm, hash}
  defp address_ref(_absent), do: nil

  defp status("ok"), do: :success
  defp status("error"), do: :reverted
  defp status(_pending), do: :pending

  # Advisory, so a failure here is `nil` rather than a failed read: the lag is
  # extra information about a height, not the height.
  defp indexer(state) do
    case get(state, "/api/v2/main-page/indexing-status") do
      {:ok, body} ->
        %{
          finished?: body["finished_indexing_blocks"] == true,
          indexed_ratio: float(body["indexed_blocks_ratio"])
        }

      {:error, _reason} ->
        nil
    end
  end

  defp latest_height(%{"items" => [%{"height" => height} | _rest]}),
    do: Backend.int(height, :height)

  defp latest_height(_body), do: {:error, {:decode_failed, :blocks}}

  defp chain_id("eip155:" <> id) do
    case Integer.parse(id) do
      {chain_id, ""} -> {:ok, chain_id}
      _unparseable -> {:error, {:unsupported_chain, id}}
    end
  end

  defp chain_id(other), do: {:error, {:unsupported_chain, other}}

  # The one place a caller's account reference becomes a path segment, so the
  # FORMAT is checked here rather than at the tool boundary: validation sits on
  # the function that performs the side effect. `is_binary/1` alone was not a
  # check -- `Raxol.Web3.Serialize.account_ref/1` builds `{:evm, value}` out of
  # anything a tool argument prefixes with `"evm:"`, so `"evm:../../admin?x=1"`
  # reached an arbitrary path and query on this host and handed the body back
  # to the model.
  #
  # Rejecting beats encoding for this one: this upstream has exactly one
  # address shape, and a percent-encoded traversal is a 404 a caller cannot act
  # on. `segment/1` still encodes every address it interpolates, and every
  # other id goes through `Raxol.Web3.Backend.PathSegment.encode/2`'s
  # allowlist, so a path parameter added later cannot reopen the hole.
  #
  # Case is carried through rather than normalized: an EIP-55 checksum is the
  # caller's own typo protection, and downcasing it would throw that away.
  defp evm_address({:evm, address}) when is_binary(address) do
    if evm_address?(address),
      do: {:ok, address},
      else: {:error, {:unsupported_account_ref, :not_an_address}}
  end

  defp evm_address({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp evm_address(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  # `0x` plus twenty bytes of hex, either case. A byte walk rather than a
  # regex: the check runs on every read and a compiled pattern buys nothing at
  # 42 characters. Bytes rather than codepoints because `to_charlist/1` RAISES
  # on a binary that is not valid UTF-8, and this one is a tool argument; a
  # byte outside `@hex_digits` is refused either way.
  defp evm_address?("0x" <> hex) when byte_size(hex) == 40 do
    hex |> :binary.bin_to_list() |> Enum.all?(&(&1 in @hex_digits))
  end

  defp evm_address?(_other), do: false

  defp float(value) when is_number(value), do: value * 1.0

  defp float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp float(_other), do: nil
end

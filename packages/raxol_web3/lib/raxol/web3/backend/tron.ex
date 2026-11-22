defmodule Raxol.Web3.Backend.Tron do
  @moduledoc """
  The Tron backend, over three MCP upstreams with three different session models.

  ADR-0033 decision 3 and ADR-0039 for the contract; `Raxol.MCP.Client` reaches
  the stateful MCP origins. Every figure below was measured on 2026-09-14
  unless it says otherwise, and the ones that are guesses say so.

  ## Three sources, three session models, one contract

  | Source | Session | Concurrency | Tools |
  | ------ | ------- | ----------- | ----- |
  | TronGrid (`mcp.trongrid.io/mcp`) | legacy, `mcp-session-id` | `:pooled` | 149 |
  | SQD Portal (`portal.sqd.dev/mcp`) | none | `:stateless` | 31 |
  | TronScan (`mcp.tronscan.org/mcp`) | legacy, `mcp-session-id` | `:serialized` | 119 |

  The concurrency policy is passed to `Raxol.MCP.Client` rather than
  reimplemented here. TronScan is the reason the policy
  exists: two parallel calls on one session answered 500 for both, reproducibly,
  while sequential calls immediately after succeeded and the session survived.

  149 plus 119 is 268 third-party tool descriptions for one chain, and
  TronGrid's `tools/list` alone was 269,860 bytes on 2026-09-14. None of that
  text reaches a served tool definition or an annotation: upstream names appear
  only as arguments this module chooses, and upstream prose travels only inside
  a result payload that the normalizers take structured
  fields out of.

  ## Two encodings for one account

  The reference is `{:tron, value}` and accepts Base58Check or hex for the same
  account. `Raxol.Web3.Tron.Address.canonical/1` collapses them, and it is
  applied ONCE, at the edge, before any request. Everything past that point holds
  Base58, so a cache key, a cursor scope and a rate-limit spend cannot differ
  by encoding for one account. The upstreams make the point themselves: a
  single `getTransactionById` response carried `owner_address` in Base58 and
  `contract_address` in hex, so normalization canonicalizes on the way out too.

  ## Three token standards, and TRC-10 has no address

  `Backend.token()`'s `address` is the TRC-20 contract. A TRC-10 asset is keyed
  by a numeric id, so `address` is `nil`, `type` is `"TRC-10"` and the id lands
  in `token_balance()`'s `token_id`, which is exactly the field a standard with
  a non-address identifier needs. A TRC-10 and a TRC-20 balance therefore come
  back from one `token_balances/3` page and are told apart by `type` without
  either of them carrying a field it does not have. The native asset is neither:
  TronScan reports it as `tokenType: "trc10"` with `tokenId: "_"`, and it is
  normalized to `type: "TRX"` with no address and no id.

  Token metadata is absent on the TronGrid source, and that is a measurement
  rather than an omission. `getTrc20Info` is the only batch metadata tool, its
  `contractList` is a comma-separated string despite an array schema, and asked
  for the 493 contracts one account held it answered with 20 records and no
  indication that it had truncated. Enriching from it would have produced
  metadata for 20 tokens out of 493 and silence about the rest. The TronScan
  source answers `token_balances/3` with `tokenDecimal` and `tokenAbbr`
  included, so a caller that needs the scale has a source that publishes it and
  a nil rather than a fabricated 18 from one that does not.

  ## The finalized split, from the irreversible view

  `block_height/1` never reports the head twice, and each source has its own
  irreversible view:

    * TronGrid: `getBlock` for the head, `solidityGetBlock` for the
      irreversible one. The 25 `solidity*` tools exist for no other reason, and
      the two numbers were 86,236,608 and 86,236,590 when measured.
    * TronScan: one descending `getBlocks` page. The head is the first row and
      the irreversible height is the highest row carrying `confirmed: true`,
      which sat 18 blocks back at 19 confirmations, matching Tron's
      two-thirds-of-27 rule.
    * SQD Portal: `portal_get_network_info` carries `head`, `finalized_head`
      and the lag in blocks and seconds, so one call answers the height and the
      indexer shape.

  `getNodeInfo` carries both numbers in one call and is deliberately not used:
  it delivers them as `"Num:N,ID:hash"` strings beside a peer list, 30,366
  bytes on 2026-09-14, against roughly 800 bytes for each structured block.

  ## What each source declares

  SQD Portal declares no optional callback at all, on the same measurement
  ADR-0039 rests on. `portal_tron_query_transactions` takes a `sighash`, which
  is a method selector and not a transaction id, so there is no by-hash lookup;
  and asked for an account's transactions with no window it answers 200
  carrying `error.code "invalid_request"` and "Provide timeframe, from_block, or
  from_timestamp/to_timestamp to define the query window". `Backend.list_opts()`
  is `[cursor: _]`, so a caller cannot supply that window and a window this
  module invented would be its own number. An archive answers ranges; the two
  required callbacks are what it knows about the chain.

  TronGrid declines `get_block/2`'s siblings it has no index for and declares
  the six reads its named tools answer. `getTransactionInfoById` is not among
  them: on 2026-09-14 it answered `isError: true` with its own output-schema
  validation failure (`/fee_major: string found, number expected`), so a
  TronGrid transaction carries a `nil` block and fee, and TronScan is the source
  in the chain that answers those.

  ## Pagination, and a ceiling the caller never sees

  TronGrid pages by an opaque `fingerprint`; TronScan pages by `start` and
  `limit` with a hard `start + limit <= 10000`. Both live behind
  `Raxol.Web3.Cursor`, so neither an offset nor a fingerprint is exposed.
  Crossing TronScan's ceiling fails rather than rewinding: the cursor is still
  minted while the upstream reports more rows, and presenting one whose page
  would cross the ceiling answers `{:upstream_refused, :unknown}` without
  spending the upstream's budget on a request its own rule refuses. The
  recorded refusal is pinned as a fixture and maps to the same error, so the
  local check and the upstream agree.
  """

  @behaviour Raxol.Web3.Backend

  import Raxol.Web3.Backend.Decode, only: [dig: 2, int: 1]

  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Era
  alias Raxol.Web3.Origin

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Paging
  alias Raxol.Web3.Backend.SQD
  alias Raxol.Web3.Backend.Tron.Errors
  alias Raxol.Web3.Backend.Tron.Normalize
  alias Raxol.Web3.Backend.Tron.Sources
  alias Raxol.Web3.Cache
  alias Raxol.Web3.MCPCall
  alias Raxol.Web3.Scope
  alias Raxol.Web3.Tables
  alias Raxol.Web3.TTL

  # `:http_opts` is an operator's own keyword list and may carry an
  # authorization header, so it is not something `inspect/1` may render: a
  # handle reaches an operator through `Raxol.Web3.Router.candidates/3`, and a
  # crash anywhere below formats the struct whole into a log line.
  @derive {Inspect, except: [:http_opts]}
  @enforce_keys [:source, :chain_ref]
  defstruct [:source, :chain_ref, :client, :scope, http_opts: [], cache?: true]

  @type source :: Sources.source()

  @type t :: %__MODULE__{
          source: source(),
          chain_ref: Backend.chain_ref(),
          client: GenServer.server() | nil,
          scope: Scope.t() | nil,
          http_opts: keyword(),
          cache?: boolean()
        }

  # A GUESS, and labelled one because Tron's documentation refuses to publish a
  # free-tier figure and warns against hardcoding the commonly cited ones. It
  # is set below every historical number rather than at one of them. A token
  # bucket rather than a window counter because TronGrid answers a burst with a
  # 30-second penalty, which a window counter forgets at its boundary.
  @rate_limit [capacity: 5, refill_per_second: 1.0]

  # A judgement, not a measurement. Small enough that one page is cheap on a
  # budget nobody publishes, large enough that a walk is not mostly round
  # trips. TronGrid accepts up to 200 and TronScan is bounded by its ceiling.
  @page_limit 25

  # Measured 2026-09-14: `start + limit` above this answers a refusal inside a
  # successful tool result. It is the offset the contract refuses to expose, so
  # it lives in a cursor and never in a return value.
  @tronscan_ceiling 10_000

  # Mirrors `Raxol.Web3.Backend.JSONRPC`: an average block time derived from
  # two real timestamps this many blocks apart, rather than the protocol
  # constant, which would be a number we asserted instead of read.
  @block_time_sample 100

  @doc """
  Build a handle for one source.

  `:client` is required for `:trongrid` and `:tronscan` and must be a running
  `Raxol.MCP.Client`; `client_spec/2` builds the child spec for one. The handle
  is data and starts no process, which is what lets a router hold three of them
  and a test hold one with a recorded transport.

  `:chain_ref` accepts `tron:0x2b6653dc` or `tron:mainnet` and is canonicalized.
  `:cache` defaults to `true`; `false` turns off the response cache for this
  handle, which a caller that must see the head on every read needs. A height is
  never cached either way.
  """
  @spec new(source(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(source, opts \\ []) when is_atom(source) do
    with {:ok, config} <- Sources.fetch(source),
         {:ok, chain_ref} <-
           Sources.canonical_chain_ref(Keyword.get(opts, :chain_ref, Sources.chain_ref())),
         {:ok, client} <- client(config, opts) do
      state = %__MODULE__{
        source: source,
        chain_ref: chain_ref,
        client: client,
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, %{state | scope: Scope.of(config.url, state.http_opts)}}}
    end
  end

  @doc """
  A child spec for the `Raxol.MCP.Client` a stateful source needs.

  The breaker table is this package's, so the health the transport records on
  the request path is the health `Raxol.Web3.Router` orders candidates by. The
  era table stays the client's, because an era verdict is the client's own
  cached decision about a protocol revision and means nothing here.

  `:concurrency` is the policy, not a suggestion: TronGrid is `:pooled` because
  six parallel calls on one session all returned 200, and TronScan is
  `:serialized` because two returned 500. A legacy origin defaults to
  `:serialized` on its own, so the second one is passed for the record rather
  than to change behaviour.

  `Raxol.MCP.Client` registers a process only when a `:registry` is supplied,
  so `:name` here labels log lines rather than the process. A handle therefore
  takes the pid the supervisor returned, or a via-tuple when a registry is in
  use, and `new/2` accepts either because both are a `GenServer.server()`.
  """
  @spec client_spec(source(), keyword()) :: Supervisor.child_spec()
  def client_spec(source, opts \\ []) when is_atom(source) do
    config = Sources.fetch!(source)
    name = Keyword.get(opts, :name, default_client_name(source))

    spec =
      opts
      |> Keyword.take([
        :exchange,
        :tables,
        :resolver,
        :registry,
        :era_ttl_ms,
        :max_bytes,
        :deadline_ms,
        :chunk_timeout_ms,
        :connect_timeout_ms
      ])
      |> Keyword.put_new_lazy(:tables, &default_tables/0)
      |> Keyword.merge(
        name: name,
        url: config.url,
        concurrency: config.concurrency
      )

    %{id: {Client, name}, start: {Client, :start_link, [spec]}}
  end

  # The era verdict and the spend reservations belong to the client, so only
  # the breaker is named here and the transport fills the other two from the
  # process-wide set. The breaker is this package's, so the health the
  # transport records on the request path is the health `Raxol.Web3.Router`
  # orders candidates by; two tables would give the router a second opinion it
  # could not see the first of.
  defp default_tables do
    %{breakers: Tables.breakers()}
  end

  @doc "The name `client_spec/2` labels a source's client with by default."
  @spec default_client_name(source()) :: atom()
  def default_client_name(source) when is_atom(source), do: :"raxol_web3_tron_#{source}"

  @doc "The source table, with its dated session and concurrency facts. Data, not behaviour."
  @spec sources() :: %{source() => map()}
  def sources, do: Sources.all()

  @doc "The accepted chain references and what each one canonicalizes to. Dated 2026-09-14."
  @spec chain_aliases() :: %{String.t() => String.t()}
  def chain_aliases, do: Sources.chain_aliases()

  @impl Backend
  def backend, do: :tron

  # The module is not the source. Three upstreams answer for this chain and
  # `backend/0` is `:tron` for all three, so `Raxol.Web3.Router.coverage/2`
  # reported `[:tron, :tron, :tron]` and an operator could read how many
  # sources survived a failover but not which one dropped out. The handle
  # already carries the source, which is the answer the coverage map wants,
  # and it is the same atom as `sources/0`'s key and `health_key/1`'s subject
  # so all three name one thing.
  @impl Backend
  def backend(%__MODULE__{source: source}), do: source

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{source: source}), do: Sources.capabilities(source)

  # Two writers, so two key shapes, and each handle names the one its own
  # outbound path records. `Raxol.Web3.HTTP` keys on a hashed origin id;
  # `Raxol.MCP.Client`'s transport keys on the plain origin string. The origin
  # comes from the dated table above and never from a caller, so no per-account
  # hostname can reach either key.
  @impl Backend
  def health_key(%__MODULE__{source: :sqd} = state), do: {:origin, origin_id(state)}
  def health_key(%__MODULE__{} = state), do: {:origin, Era.origin(uri(state))}

  @impl Backend
  def chain_info(%__MODULE__{source: :sqd} = state) do
    with {:ok, body} <- call(state, "portal_get_network_info", network(state), :chain_stats),
         :ok <- confirm_network(body) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         # An archive publishes freshness and coverage, not aggregate counters,
         # so the four totals are absent facts rather than zeros. The call is
         # still made: chain identity is confirmed against the upstream here
         # rather than asserted from the handle.
         average_block_time_ms: nil,
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  def chain_info(%__MODULE__{source: :trongrid} = state) do
    with {:ok, head} <- call(state, "getBlock", %{"detail" => false}, :chain_stats),
         {:ok, height} <- Normalize.block_number(head),
         {:ok, earlier} <- sample_block(state, height - @block_time_sample) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: average_block_time_ms(head, earlier),
         # A node keeps no aggregate counters, and a fabricated total would be
         # read as a fact about the chain.
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  def chain_info(%__MODULE__{source: :tronscan} = state) do
    with {:ok, body} <- call(state, "getStatsOverview", %{}, :chain_stats),
         {:ok, stats} <- Normalize.first_row(body, :stats_overview) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: Normalize.seconds_to_ms(stats["avgBlockTime"]),
         total_blocks: int(stats["totalBlockCount"]),
         total_transactions: int(stats["totalTransaction"]),
         total_addresses: int(stats["totalAddress"])
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{source: :sqd} = state) do
    with {:ok, body} <- call(state, "portal_get_network_info", network(state)),
         {:ok, height} <- Normalize.dig_int(body, ["head", "number"], :sqd_head) do
      {:ok,
       %{
         height: height,
         finalized_height: int(dig(body, ["finalized_head", "number"])),
         unit: :block,
         indexer: Normalize.sqd_indexer(body)
       }}
    end
  end

  def block_height(%__MODULE__{source: :trongrid} = state) do
    with {:ok, head} <- call(state, "getBlock", %{"detail" => false}),
         {:ok, height} <- Normalize.block_number(head),
         {:ok, irreversible} <- call(state, "solidityGetBlock", %{"detail" => false}),
         {:ok, finalized} <- Normalize.block_number(irreversible) do
      # `indexer: nil` rather than a cheerful `%{finished?: true}`: this
      # upstream publishes no indexing status, and claiming a component is
      # healthy is worse than saying nothing about it.
      {:ok, %{height: height, finalized_height: finalized, unit: :block, indexer: nil}}
    end
  end

  def block_height(%__MODULE__{source: :tronscan} = state) do
    query = %{"limit" => @page_limit, "sort" => "-number"}

    with {:ok, body} <- call(state, "getBlocks", query),
         {:ok, rows} <- Normalize.rows(body, :blocks),
         {:ok, height} <- Normalize.first_block_number(rows) do
      {:ok,
       %{
         height: height,
         finalized_height: Normalize.highest_confirmed(rows),
         unit: :block,
         indexer: nil
       }}
    end
  end

  @impl Backend
  def get_transaction(%__MODULE__{source: :trongrid} = state, hash) when is_binary(hash) do
    with {:ok, body} <- call(state, "getTransactionById", %{"value" => hash}, :transaction) do
      Normalize.trongrid_transaction(body)
    end
  end

  def get_transaction(%__MODULE__{source: :tronscan} = state, hash) when is_binary(hash) do
    with {:ok, body} <- call(state, "getTransactionDetail", %{"hash" => hash}, :transaction) do
      Normalize.tronscan_transaction(body)
    end
  end

  @impl Backend
  def account_info(%__MODULE__{source: :trongrid} = state, account_ref) do
    with {:ok, address} <- Normalize.account(account_ref),
         {:ok, body} <- call(state, "getAccountInfo", %{"address" => address}, :account),
         {:ok, record} <- Normalize.first_row(body, :account),
         {:ok, balance} <- Backend.money(record["balance"], :balance) do
      {:ok,
       %{
         ref: {:tron, Normalize.canonical_or(record["address"], address)},
         balance: balance,
         # Code presence, from the account record's own account type. No
         # `:kind`: Tron draws no distinction that changes how `balance` is
         # read, and `contract?` already answers the only one it draws.
         contract?: record["type"] == "Contract",
         verified?: false,
         name: nil,
         ens: nil
       }}
    end
  end

  def account_info(%__MODULE__{source: :tronscan} = state, account_ref) do
    with {:ok, address} <- Normalize.account(account_ref),
         {:ok, body} <- call(state, "getAccountDetail", %{"address" => address}, :account),
         {:ok, balance} <- Backend.money(body["balance"], :balance) do
      {:ok,
       %{
         ref: {:tron, Normalize.canonical_or(body["address"], address)},
         balance: balance,
         contract?: is_map(body["contractInfo"]) or body["accountType"] == 2,
         verified?: false,
         # The explorer's own label for the address, which is data in a result
         # payload rather than a tool description, and `nil` when unlabelled.
         name: Normalize.presence(body["addressTag"]),
         ens: nil
       }}
    end
  end

  @impl Backend
  def list_transactions(%__MODULE__{source: :trongrid} = state, account_ref, opts \\ []) do
    with {:ok, address} <- Normalize.account(account_ref) do
      fingerprint_page(
        state,
        "getAccountTransactions",
        %{"address" => address},
        :tron_account_transactions,
        opts,
        &Normalize.trongrid_list_transaction/1
      )
    end
  end

  @impl Backend
  def token_balances(state, account_ref, opts \\ [])

  def token_balances(%__MODULE__{source: :trongrid} = state, account_ref, opts) do
    with :ok <- Paging.no_cursor(Keyword.get(opts, :cursor)),
         {:ok, address} <- Normalize.account(account_ref),
         {:ok, body} <- call(state, "getAccountInfo", %{"address" => address}, :account),
         {:ok, record} <- Normalize.first_row(body, :account),
         {:ok, items} <- Normalize.trongrid_token_balances(record) do
      # One call and no cursor: the account record is one object rather than a
      # page, so `next` is `nil` because there is no second page and not
      # because paging was declined. Measured 2026-09-14, the widest holder
      # probed returned 493 TRC-20 and 331 TRC-10 entries in 26,795 bytes.
      {:ok, %{items: items, next: nil}}
    end
  end

  def token_balances(%__MODULE__{source: :tronscan} = state, account_ref, opts) do
    with {:ok, address} <- Normalize.account(account_ref) do
      offset_page(
        state,
        "getAccountTokens",
        %{"address" => address},
        :tronscan_account_tokens,
        opts,
        &Normalize.tronscan_token_balance/1
      )
    end
  end

  @impl Backend
  def list_token_transfers(state, account_ref, opts \\ [])

  def list_token_transfers(%__MODULE__{source: :trongrid} = state, account_ref, opts) do
    with {:ok, address} <- Normalize.account(account_ref) do
      fingerprint_page(
        state,
        "getAccountTrc20Transactions",
        %{"address" => address},
        :tron_account_trc20_transfers,
        opts,
        &Normalize.trongrid_token_transfer/1
      )
    end
  end

  def list_token_transfers(%__MODULE__{source: :tronscan} = state, account_ref, opts) do
    with {:ok, address} <- Normalize.account(account_ref) do
      offset_page(
        state,
        "getTransferList",
        %{"address" => address},
        :tronscan_transfer_list,
        opts,
        &Normalize.tronscan_token_transfer/1
      )
    end
  end

  @impl Backend
  def get_block(%__MODULE__{source: :trongrid} = state, number) do
    query = %{"detail" => false, "id_or_num" => to_string(number)}

    with {:ok, body} <- call(state, "getBlock", query, :block) do
      {:ok, Normalize.trongrid_block(body)}
    end
  end

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is built from the tool name and the argument map
  # this module composed, never from an assembled URI, so a credential cannot
  # reach a cache key by construction rather than by review.
  defp call(state, tool, arguments, class \\ nil) do
    case cache_key(state, tool, arguments, class) do
      nil -> dispatch(state, tool, arguments, [])
      key -> through_cache(state, tool, arguments, key, class)
    end
  end

  # The stateless source caches inside `Raxol.Web3.HTTP`, which is where
  # ADR-0038 decision 2 puts the stage: after the vet, so a hit cannot answer
  # for a target that has since resolved into the reject set, and before the
  # token bucket, so a hit spends nobody's budget. A stateful source cannot
  # reach that stage, because its outbound path is `Raxol.MCP.Client`, so the
  # same table and the same TTL class are applied one layer up. Both key on
  # the source's scope, so the key shape is the same either way.
  defp through_cache(%__MODULE__{source: :sqd} = state, tool, arguments, key, class) do
    dispatch(state, tool, arguments, cache: [key: {scope(state), key}, ttl_ms: TTL.for(class)])
  end

  defp through_cache(%__MODULE__{} = state, tool, arguments, key, class) do
    full_key = {scope(state), key}

    case Cache.get(full_key) do
      {:ok, payload} ->
        {:ok, payload}

      :miss ->
        with {:ok, payload} = ok <- dispatch(state, tool, arguments, []) do
          Cache.put(full_key, payload, TTL.for(class))
          ok
        end
    end
  end

  defp cache_key(%__MODULE__{cache?: false}, _tool, _arguments, _class), do: nil
  defp cache_key(_state, _tool, _arguments, nil), do: nil
  defp cache_key(_state, tool, arguments, _class), do: {tool, arguments}

  defp dispatch(%__MODULE__{source: :sqd} = state, tool, arguments, extra) do
    case MCPCall.call(url(state), tool, arguments, http_opts(state, extra)) do
      {:ok, payload} -> sqd_result(state, payload)
      {:tool_error, payload} -> {:error, sqd_refusal(state, payload)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(%__MODULE__{client: nil}, _tool, _arguments, _extra) do
    {:error, {:transport, :no_client}}
  end

  defp dispatch(%__MODULE__{client: client}, tool, arguments, _extra) do
    case call_tool(client, tool, arguments) do
      {:ok, %{content: content, is_error: false}} -> Errors.content_payload(content)
      {:ok, %{is_error: true}} -> {:error, {:upstream_refused, :unknown}}
      {:error, reason} -> {:error, Errors.client_error(reason)}
    end
  end

  # `Raxol.MCP.Client.call_tool/3` is a `GenServer.call`, and a `case` does not
  # catch an exit. A client that died between the handle being built and the
  # read exits the CALLER with `{:noproc, _}`. A slow exchange exits it with
  # `{:timeout, _}`: both timers are 30s, but the caller's starts when the
  # call is issued and the client's own `call_timeout` only when the request
  # is dispatched, so on a `:serialized` or `:pooled` source anything spent
  # queueing is time the caller's timer has and the client's has not.
  # Either way the process that dies is the READER -- a router candidate, or
  # whatever served the MCP tool call -- so the failover that exists for
  # exactly this case never runs. Both map onto reasons
  # `Raxol.Web3.Router.failover?/1` moves on.
  defp call_tool(client, tool, arguments) do
    Client.call_tool(client, tool, arguments)
  catch
    :exit, {:timeout, _call} -> {:error, {:timeout, :deadline}}
    :exit, _down -> {:error, {:transport, :client_down}}
  end

  defp http_opts(state, extra) do
    state.http_opts
    |> Keyword.put_new(:rate_limit, @rate_limit)
    |> Keyword.merge(extra)
  end

  # SQD announces a refusal as a nested object with a machine-readable code,
  # and it puts that object in both places a tool result can carry one: an
  # `isError: true` result, and a plain result whose payload is the object.
  # Both arms are read, and the reading is `Raxol.Web3.Backend.SQD`'s so that
  # this backend and `Raxol.Web3.Backend.Solana` classify the endpoint alike.
  defp sqd_result(state, payload) do
    case SQD.refusal(payload, network_name(state)) do
      nil -> Errors.payload_result(payload)
      reason -> {:error, reason}
    end
  end

  defp sqd_refusal(state, payload), do: SQD.announced(payload, network_name(state))

  defp origin_id(state), do: Origin.for_url(uri(state))

  defp scope(state), do: state.scope

  defp uri(%__MODULE__{} = state), do: URI.new!(url(state))

  defp url(%__MODULE__{source: source}), do: Sources.fetch!(source).url

  defp network(%__MODULE__{} = state), do: %{"network" => network_name(state)}

  defp network_name(%__MODULE__{source: source}), do: Sources.fetch!(source).network

  # Chain identity, confirmed rather than asserted. The upstream names the
  # network and the VM family it indexed, and a handle that asked for Tron and
  # was answered about something else is a misconfiguration worth failing on.
  defp confirm_network(%{"vm" => "tron", "network_type" => "mainnet"}), do: :ok
  defp confirm_network(_body), do: {:error, {:decode_failed, :network_identity}}

  # TronGrid pages on an opaque `fingerprint`. `meta.links.next` is a full
  # upstream URL carrying that fingerprint, and it is read only as the signal
  # that another page exists: the next request is composed here from the tool
  # and the argument map, never by following somebody else's URL.
  defp fingerprint_page(state, tool, base, endpoint, opts, mapper) do
    with {:ok, params} <-
           Paging.cursor_params(Keyword.get(opts, :cursor), scope(state), endpoint),
         arguments = Map.merge(base, Map.put(params, "limit", @page_limit)),
         {:ok, body} <- call(state, tool, arguments, :list),
         {:ok, rows} <- Normalize.rows(body, :page),
         {:ok, items} <- Backend.map_rows(rows, mapper, endpoint) do
      {:ok,
       %{
         items: items,
         next: Paging.next_cursor(next_fingerprint(body), scope(state), endpoint)
       }}
    end
  end

  # TronScan pages on `start` and `limit`. The ceiling is checked before the
  # request rather than after it, so a walk that would cross it fails without
  # spending a token on a request the upstream documents as refused, and the
  # error is the same one the upstream's own refusal maps to.
  defp offset_page(state, tool, base, endpoint, opts, mapper) do
    with {:ok, params} <-
           Paging.cursor_params(Keyword.get(opts, :cursor), scope(state), endpoint),
         start = int(params["start"]) || 0,
         :ok <- within_ceiling(start),
         arguments = Map.merge(base, %{"start" => start, "limit" => @page_limit}),
         {:ok, body} <- call(state, tool, arguments, :list),
         {:ok, rows} <- Normalize.rows(body, :page),
         {:ok, items} <- Backend.map_rows(rows, mapper, endpoint) do
      {:ok,
       %{
         items: items,
         next: Paging.next_cursor(next_offset(body, start), scope(state), endpoint)
       }}
    end
  end

  defp within_ceiling(start) when start + @page_limit <= @tronscan_ceiling, do: :ok
  defp within_ceiling(_start), do: {:error, {:upstream_refused, :unknown}}

  defp next_fingerprint(body) do
    with %{"meta" => %{"fingerprint" => fingerprint} = meta} <- body,
         true <- is_binary(dig(meta, ["links", "next"])) do
      %{"fingerprint" => fingerprint}
    else
      _last_page -> nil
    end
  end

  # `total` is the upstream's own row count, so "there is another page" is read
  # from it rather than guessed from a full page.
  defp next_offset(body, start) do
    next = start + @page_limit

    case int(body["total"]) do
      total when is_integer(total) and next < total ->
        %{"start" => next, "limit" => @page_limit}

      _end_of_walk ->
        nil
    end
  end

  defp sample_block(state, height) when height > 0 do
    call(state, "getBlock", %{"detail" => false, "id_or_num" => to_string(height)}, :block)
  end

  defp sample_block(_state, _height), do: {:error, {:decode_failed, :block}}

  defp average_block_time_ms(head, earlier) do
    newer = int(dig(head, ["block_header", "raw_data", "timestamp"]))
    older = int(dig(earlier, ["block_header", "raw_data", "timestamp"]))

    if is_integer(newer) and is_integer(older) and newer > older do
      (newer - older) / @block_time_sample
    end
  end

  defp client(%{stateful?: false}, _opts), do: {:ok, nil}

  defp client(%{stateful?: true}, opts) do
    case Keyword.get(opts, :client) do
      nil -> {:error, :client_required}
      client -> {:ok, client}
    end
  end
end

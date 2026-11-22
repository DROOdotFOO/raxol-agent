defmodule Raxol.Web3.Backend.Solana do
  @moduledoc """
  The Solana backend, over two sources that answer different questions.

  `new/2` builds one handle per `source: :sqd | :rpc`, since each declares only
  what it answers; route them with `Raxol.Web3.Router.new([sqd, rpc])`.
  `backend/1` is `:solana_sqd` or `:solana_rpc`; `backend/0` is `:solana`.

  | Callback | SQD Portal | Public RPC |
  | -------- | ---------- | ---------- |
  | `chain_info/1` | `portal_get_network_info` | `getEpochInfo` |
  | `block_height/1` | `portal_get_head` twice | `getSlot` twice |
  | `get_transaction/2` | no | `getTransaction` |
  | `account_info/2` | no | `getAccountInfo` |
  | `token_balances/3` | no | `getTokenAccountsByOwner` |
  | `list_transactions/3` | no | `getSignaturesForAddress` |
  | `get_block/2` | no | `getBlock` |

  Each "no" is an absent capability (ADR-0039): SQD has no signature lookup,
  needs a time window for account queries, and reports no current balance.

  ## Heights are slots

  Both sources report `unit: :slot`; a slot is not a block height (the two
  differed by about 22 million when measured). SQD reads `latest` and
  `finalized` heads and reports their clamped difference as `lag_blocks`; RPC
  reads `getSlot` at `processed` and `finalized` and reports `indexer: nil`.

  `get_block/2` answers the requested slot as `height`. A skipped slot
  (JSON-RPC -32009) is `{:ok, block}` with `hash: nil`; a produced slot always
  carries a hash. `blockHeight` and the leader identity are not reported.

  ## Accounts, transactions and paging

  `account()` carries `kind`: `:program` (executable), `:wallet` (system
  owned), `:token_account` and `:mint` (SPL token program, by `space`), or
  `:data`. A token account's `balance` is its rent reserve; its holding is in
  `token_balances/3`. An account with no value is `{:upstream_refused,
  :not_found}`, never zero.

  `list_transactions/3` pages on `before` via `:solana_address_signatures`; a
  non-empty page always mints a cursor and only an empty page ends the walk.
  Rows carry no counterparties. `token_balances/3` answers the whole set in
  one response, so `next` is `nil` and a held cursor is `{:invalid_cursor,
  :wrong_scope}`. `get_transaction/2` reports the fee payer as `from` and
  leaves `to`, `value` and `method` `nil`.

  Commitment is per read: `get_transaction/2` and `list_transactions/3` at
  `confirmed` (readable once landed, not settled: compare `block` with
  `finalized_height`); `account_info/2` and `token_balances/3` at
  `finalized`; `block_height/1` at `processed` and `finalized`; `get_block/2`
  at the node default, `finalized`.

  ## Networks, limits, declines

  SQD's networks come from `portal_list_networks` under the `:catalog` TTL; an
  unlisted network is `{:unsupported_chain, _}` and fails over. Mainnet is
  `solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp`, with `solana:mainnet` as alias.
  RPC's bucket follows its documented 100 per 10 s per IP (the per-method cap
  is not enforced here); SQD's seed is a guess. `raw_request/2` and
  `list_token_transfers/3` are not implemented. Upstream prose fields such as
  `answer` and `display_name` are never read.
  """

  @behaviour Raxol.Web3.Backend

  import Raxol.Web3.Backend.Decode, only: [ok_or: 2, rows_of: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.Backend.Paging
  alias Raxol.Web3.Backend.Solana.Normalize
  alias Raxol.Web3.Backend.Solana.RPC
  alias Raxol.Web3.Backend.SQD
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.MCPCall

  # `:http_opts` is an operator's own keyword list and may carry an
  # authorization header, and an operator's `:url` override often embeds a
  # provider key, so neither is something `inspect/1` may render: a handle
  # reaches an operator through `Raxol.Web3.Router.candidates/3`, and a crash
  # anywhere below formats the struct whole into a log line.
  @derive {Inspect, except: [:url, :http_opts]}
  @enforce_keys [:chain_ref, :source, :url, :network]
  defstruct [:chain_ref, :source, :url, :network, http_opts: [], cache?: true]

  @type source :: :sqd | :rpc

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          source: source(),
          url: String.t(),
          network: String.t(),
          http_opts: keyword(),
          cache?: boolean()
        }

  @mainnet "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"

  # Dated data, 2026-09-14. A compile-time map rather than a parse plus
  # `String.to_existing_atom/1`, which would depend on an atom having been
  # interned somewhere else.
  @chain_aliases %{
    @mainnet => @mainnet,
    "solana:mainnet" => @mainnet
  }

  @chains %{
    @mainnet => %{
      network: "solana-mainnet",
      rpc_url: "https://api.mainnet-beta.solana.com",
      sqd_url: "https://portal.sqd.dev/mcp"
    }
  }

  @sources [:sqd, :rpc]

  # SQD declares nothing optional, which is the asymmetry this backend exists
  # to express, and every entry in the RPC list is measured in the moduledoc.
  @rpc_capabilities [
    :get_transaction,
    :account_info,
    :token_balances,
    :list_transactions,
    :get_block
  ]

  # A guess: SQD publishes no rate limit.
  @sqd_rate_limit [capacity: 10, refill_per_second: 2.0]

  # A judgement: the upstream maximum is 1000 and one page should stay small.
  @page_limit 100

  # The catalog's Solana family was 7 of 139 networks with `has_more: false` on
  # 2026-09-14, so one page of 100 covers it. If it ever outgrows a page, an
  # unlisted network is `{:unsupported_chain, _}`, which is a refusal rather
  # than a wrong answer.
  @catalog_limit 100

  @finalized %{"commitment" => "finalized"}

  # `dataSlice` with a zero length is what keeps an account read at 250 bytes:
  # the fields that classify an account are in the envelope, never in its data.
  @account_config %{
    "encoding" => "base64",
    "commitment" => "finalized",
    "dataSlice" => %{"offset" => 0, "length" => 0}
  }

  @parsed_config %{"encoding" => "jsonParsed", "commitment" => "finalized"}

  # `confirmed` rather than `finalized`, deliberately: a transaction the cluster has
  # confirmed exists, and answering `not_found` until it finalizes would hide
  # it during the window a caller most needs to read it.
  @transaction_config %{
    "encoding" => "json",
    "commitment" => "confirmed",
    "maxSupportedTransactionVersion" => 0
  }

  @block_config %{
    "encoding" => "json",
    "transactionDetails" => "signatures",
    "rewards" => false,
    "maxSupportedTransactionVersion" => 0
  }

  # The Bitcoin alphabet, which omits 0, O, I and l. Input hygiene, not
  # authentication: it keeps a junk reference out of an upstream request.
  @base58 ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc """
  Build a handle for a chain reference and one source.

  Options:

    * `:source` - `:sqd` (the archive) or `:rpc` (a validator). Defaults to
      `:sqd`, the primary. One handle is one source, so a router assembled as
      `[sqd, rpc]` orders them.
    * `:url` - overrides the source's endpoint, for an operator running their
      own RPC node or portal.
    * `:network` - names the SQD network directly, for one this dated table does
      not carry yet. It is validated against the live catalog on the first read,
      so a wrong value is `{:unsupported_chain, _}` rather than a bad request.
    * `:http_opts` - forwarded to `Raxol.Web3.HTTP` unchanged.
    * `:cache` - defaults to `true`. `false` turns off the response cache for
      this handle, which a caller that must see the head needs. A height is
      never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, canonical, chain} <- canonical_chain(chain_ref),
         {:ok, source} <- source(Keyword.get(opts, :source, :sqd)),
         {:ok, url} <- base_url(Keyword.get(opts, :url), endpoint(source, chain)) do
      {:ok, {__MODULE__, handle_state(canonical, chain, source, url, opts)}}
    end
  end

  @doc "The chain references this backend accepts, and what each canonicalizes to."
  @spec chain_aliases() :: %{String.t() => String.t()}
  def chain_aliases, do: @chain_aliases

  @impl Backend
  def backend, do: :solana

  @impl Backend
  def backend(%__MODULE__{source: :sqd}), do: :solana_sqd
  def backend(%__MODULE__{source: :rpc}), do: :solana_rpc

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{source: :sqd}), do: []
  def capabilities(%__MODULE__{source: :rpc}), do: @rpc_capabilities

  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, origin_id(state)}

  @impl Backend
  def chain_info(%__MODULE__{source: :sqd} = state) do
    with {:ok, network} <- resolve(state),
         {:ok, payload} <-
           sqd(state, "portal_get_network_info", %{"network" => network.network}, :chain_stats) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         # No tool reports one, and deriving a figure from the 31-slot
         # finality lag would have the precision of a guess.
         average_block_time_ms: nil,
         # A count of indexed blocks, as Blockscout's `total_blocks` is, and
         # not a height: `block_height/1` is the height.
         total_blocks: indexed_blocks(payload),
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  def chain_info(%__MODULE__{source: :rpc} = state) do
    case RPC.call(state, "getEpochInfo", [@finalized], :chain_stats) do
      {:ok, body} when is_map(body) ->
        {:ok,
         %{
           chain_ref: state.chain_ref,
           average_block_time_ms: nil,
           # `blockHeight` is a count of blocks produced, which is what this
           # field means. The slot count is `block_height/1`'s answer.
           total_blocks: body["blockHeight"],
           total_transactions: body["transactionCount"],
           total_addresses: nil
         }}

      {:ok, _other} ->
        {:error, {:decode_failed, :epoch_info}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl Backend
  def block_height(%__MODULE__{source: :sqd} = state) do
    with {:ok, network} <- resolve(state),
         {:ok, latest} <- sqd_head(state, network.network, "latest"),
         {:ok, finalized} <- sqd_head(state, network.network, "finalized") do
      {:ok,
       %{
         height: latest,
         finalized_height: finalized,
         unit: :slot,
         indexer: %{finished?: network.real_time?, lag_blocks: max(latest - finalized, 0)}
       }}
    end
  end

  def block_height(%__MODULE__{source: :rpc} = state) do
    with {:ok, height} <- RPC.slot(state, "processed"),
         {:ok, finalized} <- RPC.slot(state, "finalized") do
      {:ok, %{height: height, finalized_height: finalized, unit: :slot, indexer: nil}}
    end
  end

  @doc """
  One transaction by signature, read at `confirmed`.

  This is the level at which a just-landed transaction is readable, and it
  is not settlement. A caller
  that settles compares the returned `block` against `block_height/1`'s
  `finalized_height`.
  """
  @impl Backend
  def get_transaction(%__MODULE__{source: :rpc} = state, signature) when is_binary(signature) do
    with {:ok, checked} <- base58(signature, 43, 90),
         {:ok, body} <-
           RPC.call(state, "getTransaction", [checked, @transaction_config], :transaction) do
      case body do
        nil -> {:error, {:upstream_refused, :not_found}}
        body -> Normalize.transaction(body)
      end
    end
  end

  # One request, not two. `getBalance` and `getAccountInfo` return the same
  # number: measured 2026-09-14, both answered 38,298,783,833 lamports for the
  # same wallet, and the account envelope carries `lamports` beside the `owner`,
  # `executable` and `space` that classify the account. Asking twice would
  # spend two of a hundred requests per ten seconds for one number.
  @impl Backend
  def account_info(%__MODULE__{source: :rpc} = state, account_ref) do
    with {:ok, pubkey} <- pubkey(account_ref),
         {:ok, account} <- RPC.call(state, "getAccountInfo", [pubkey, @account_config], :account) do
      case account do
        %{"value" => nil} -> {:error, {:upstream_refused, :not_found}}
        %{"value" => info} -> Normalize.account_record(pubkey, info)
        _envelope -> {:error, {:decode_failed, :account}}
      end
    end
  end

  @impl Backend
  def token_balances(%__MODULE__{source: :rpc} = state, account_ref, opts \\ []) do
    with {:ok, pubkey} <- pubkey(account_ref),
         :ok <- Paging.no_cursor(Keyword.get(opts, :cursor)),
         {:ok, body} <-
           RPC.call(
             state,
             "getTokenAccountsByOwner",
             [pubkey, %{"programId" => Normalize.token_program()}, @parsed_config],
             :list
           ),
         {:ok, rows} <- Normalize.token_accounts(body),
         {:ok, items} <- Backend.map_rows(rows, &Normalize.token_balance/1, :token_balance_row) do
      {:ok, %{items: items, next: nil}}
    end
  end

  @doc """
  One page of an account's signatures, read at `confirmed`.

  The same level, and the same caveat, as `get_transaction/2`.
  """
  @impl Backend
  def list_transactions(%__MODULE__{source: :rpc} = state, account_ref, opts \\ []) do
    with {:ok, rows} <- signature_page(state, account_ref, Keyword.get(opts, :cursor)),
         {:ok, items} <- Backend.map_rows(rows, &Normalize.signature_row/1, :signature_row) do
      {:ok, %{items: items, next: next_cursor(state, rows)}}
    end
  end

  # The upstream rows, not the decoded items: `next_cursor/2` reads the
  # signature off the last row as the upstream wrote it.
  defp signature_page(state, account_ref, cursor) do
    with {:ok, pubkey} <- pubkey(account_ref),
         {:ok, params} <-
           Paging.cursor_params(cursor, origin_id(state), :solana_address_signatures),
         {:ok, body} <-
           RPC.call(state, "getSignaturesForAddress", [pubkey, page_config(params)], :list) do
      Normalize.signature_rows(body)
    end
  end

  @impl Backend
  def get_block(%__MODULE__{source: :rpc} = state, slot) do
    with {:ok, number} <- slot_number(slot) do
      state
      |> RPC.raw("getBlock", [number, @block_config], :block)
      |> Normalize.block_result(number)
    end
  end

  defp resolve(state) do
    arguments = %{"vm" => "solana", "limit" => @catalog_limit}

    with {:ok, payload} <- sqd(state, "portal_list_networks", arguments, :catalog) do
      payload
      |> Map.get("items")
      |> rows_of()
      |> Enum.find_value(&match_network(&1, state.network))
      |> case do
        nil -> {:error, {:unsupported_chain, state.network}}
        network -> {:ok, network}
      end
    end
  end

  # The aliases come from the live response rather than from a table here, so
  # `solana`, `sol` and `solana-beta` resolve without this module tracking them.
  defp match_network(%{"network" => name} = item, wanted) when is_binary(name) do
    if name == wanted or wanted in rows_of(Map.get(item, "aliases")) do
      %{network: name, real_time?: item["real_time"] == true}
    end
  end

  defp match_network(_item, _wanted), do: nil

  defp sqd_head(state, network, type) do
    arguments = %{"network" => network, "type" => type}

    with {:ok, payload} <- sqd(state, "portal_get_head", arguments, nil) do
      case payload["number"] do
        number when is_integer(number) -> {:ok, number}
        _absent -> {:error, {:decode_failed, :head}}
      end
    end
  end

  defp indexed_blocks(%{"head" => %{"number" => head}, "start_block" => start})
       when is_integer(head) and is_integer(start),
       do: head - start + 1

  defp indexed_blocks(_payload), do: nil

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is the tool and its own arguments, never an
  # assembled URI, which is what keeps a credential out of a cache key by
  # construction rather than by review.
  defp sqd(state, tool, arguments, class) do
    opts =
      state.http_opts
      |> Keyword.put_new(:rate_limit, @sqd_rate_limit)
      |> Cache.opts(state.cache?, {tool, arguments}, class)

    case MCPCall.call(state.url, tool, arguments, opts) do
      {:ok, payload} -> sqd_result(payload, state)
      {:tool_error, payload} -> {:error, SQD.announced(payload, state.network)}
      {:error, _reason} = error -> error
    end
  end

  # Both places this endpoint puts a refusal are read, through
  # `Raxol.Web3.Backend.SQD`, as `Raxol.Web3.Backend.Tron` does.
  defp sqd_result(payload, state) do
    case SQD.refusal(payload, state.network) do
      nil -> {:ok, payload}
      reason -> {:error, reason}
    end
  end

  defp page_config(params) do
    Map.merge(%{"limit" => @page_limit, "commitment" => "confirmed"}, params)
  end

  defp next_cursor(state, items) do
    case items |> List.last() |> signature() do
      nil ->
        nil

      signature ->
        Cursor.encode(%{"before" => signature}, origin_id(state), :solana_address_signatures)
    end
  end

  defp origin_id(state), do: Paging.origin_id(state.url)

  defp signature(%{"signature" => signature}) when is_binary(signature), do: signature
  defp signature(_absent), do: nil

  defp canonical_chain(chain_ref) do
    with {:ok, canonical} <- canonical(chain_ref),
         {:ok, chain} <-
           Map.fetch(@chains, canonical) |> ok_or({:unsupported_chain, chain_ref}) do
      {:ok, canonical, chain}
    end
  end

  defp canonical(chain_ref) when is_binary(chain_ref) do
    Map.fetch(@chain_aliases, chain_ref) |> ok_or({:unsupported_chain, chain_ref})
  end

  defp canonical(other), do: {:error, {:unsupported_chain, other}}

  defp source(source) when source in @sources, do: {:ok, source}
  defp source(other), do: {:error, {:unsupported_source, other}}

  defp endpoint(:sqd, chain), do: chain.sqd_url
  defp endpoint(:rpc, chain), do: chain.rpc_url

  # Validated at construction rather than at the first read: `origin_id/1` is
  # `URI.new!/1` on this value, `health_key/1` reaches it, and a router
  # ordering candidates called that before any request went out. So a URL
  # that is not one failed the router rather than the handle that carried it.
  # `Raxol.Web3.Backend.Aztec.new/2` refuses the same three ways, and the
  # scheme is fixed because `Raxol.Web3.HTTP` vets `schemes: [:https]` and
  # would refuse anything else on the way out anyway.
  defp base_url(nil, default), do: {:ok, default}

  defp base_url(url, _default) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> {:ok, url}
      {:ok, %URI{scheme: "https"}} -> {:error, {:invalid_base_url, :host}}
      {:ok, %URI{}} -> {:error, {:invalid_base_url, :scheme}}
      {:error, _part} -> {:error, {:invalid_base_url, :url}}
    end
  end

  defp base_url(_other, _default), do: {:error, {:invalid_base_url, :type}}

  defp handle_state(chain_ref, chain, source, url, opts) do
    %__MODULE__{
      chain_ref: chain_ref,
      source: source,
      url: url,
      network: Keyword.get(opts, :network, chain.network),
      http_opts: Keyword.get(opts, :http_opts, []),
      cache?: Keyword.get(opts, :cache, true)
    }
  end

  defp pubkey({:solana, value}), do: base58(value, 32, 44)
  defp pubkey({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp pubkey(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  # Bytes rather than codepoints: `to_charlist/1` RAISES on a binary that is
  # not valid UTF-8, and this one arrives as a tool argument. The alphabet is
  # ASCII, so the two readings agree on every value that could be an address
  # and differ only on the ones this refuses.
  defp base58(value, min, max) when is_binary(value) do
    characters = :binary.bin_to_list(value)

    if length(characters) in min..max and Enum.all?(characters, &(&1 in @base58)) do
      {:ok, value}
    else
      {:error, {:unsupported_account_ref, :not_base58}}
    end
  end

  defp base58(_value, _min, _max), do: {:error, {:unsupported_account_ref, :unknown}}

  defp slot_number(slot) when is_integer(slot) and slot >= 0, do: {:ok, slot}

  defp slot_number(slot) when is_binary(slot) do
    case Integer.parse(slot) do
      {number, ""} when number >= 0 -> {:ok, number}
      _unparseable -> {:error, {:decode_failed, :slot}}
    end
  end

  defp slot_number(_other), do: {:error, {:decode_failed, :slot}}
end

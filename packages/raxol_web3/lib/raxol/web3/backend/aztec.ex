defmodule Raxol.Web3.Backend.Aztec do
  @moduledoc """
  The Aztec backend, against the Aztecscan (`chicmoz`) REST surface.

  **Public state only.** Aztec's private state is notes, unobservable by
  construction, so every read here answers about the public half and anything
  that needs the private half is absent from `capabilities/1` (ADR-0039
  decision 3) rather than answered emptily. Paths were probed on 2026-09-14
  and the shapes are pinned by fixtures in `test/fixtures/aztec`; the
  responses are unspecified upstream, so re-probe on upgrade.

  ## A temporary path, and what revocation looks like

  The default source is `https://api.aztecscan.xyz/v1/temporary-api-key`, a
  path segment that may be withdrawn. A withdrawn prefix answers 404, which
  `Raxol.Web3.HTTP` records as breaker success, so the failover comes from
  classification instead:

    * a 404 on a parameterless endpoint (`/l2/info`, `/l2/tips`,
      `/l2/stats/*`) is the source gone: `{:source_unavailable, :endpoint}`,
      which fails over;
    * a 404 on an addressed endpoint (block, transaction, contract instance)
      is an answer: `{:upstream_refused, :not_found}`, which does not.

  A 403 stays `{:http, 403}`. The fallback is a self-hosted `chicmoz` passed
  as `:base_url`; `chain_info/1` refuses an instance whose `l2NetworkId` is
  not this handle's network. `backend/1` reads `:aztecscan` on the temporary
  path and `:chicmoz` otherwise, judged from the resolved URL.

  ## Heights

  The unit is `:block`: blocks carry both a block number and a slot number,
  and slots skip. `block_height/1` takes `height` and `finalized_height` from
  one `l2/tips` response, so the pair is from one instant; a non-monotone
  ladder is `{:decode_failed, :tips}`. Per-block `nativeStatus` is not used
  because it is neither monotone nor consistent across views. `indexer`
  reports `finished?` (not `stale`) and `lag_seconds` (`stalenessMs`) and
  omits the measures this source does not publish; `degraded` is on `tips/1`.

  ## Transactions

  `l2/txs` is the pending pool. `get_transaction/2` reads
  `l2/tx-effects/{hash}` and falls back to the pool on a 404, which is what
  makes `:pending` an observation. `from`, `to` and `value` are `nil`: the
  record carries a fee payer (possibly a paymaster) and an `initiator` whose
  meaning is not established, and neither is a sender.

  ## Not declared

  `token_balances/3`, `account_info/2`, `list_transactions/3` and `get_logs/3`
  would each answer with the public half only, which a caller cannot tell from
  a complete answer. `read_contract/2` needs a PXE. `resolve_name/2`,
  `list_nfts/3`, `list_token_transfers/3` and `raw_request/2` have no upstream.
  The unpaginated `l2/contract-instances` and `l2/contract-classes` lists
  (over 2 MB each) are never called, and nothing here paginates, so there is
  no `Raxol.Web3.Cursor` entry.
  """

  @behaviour Raxol.Web3.Backend

  import Raxol.Web3.Backend.Decode, only: [dig: 2, ok_or: 2]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.Backend.Decode
  alias Raxol.Web3.Backend.PathSegment
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Scope

  # `:http_opts` is an operator's own keyword list and may carry an
  # authorization header, and `:base_url` carries the API key as a path
  # segment (`/v1/<key>`), so neither is something `inspect/1` may render: a
  # handle reaches an operator through `Raxol.Web3.Router.candidates/3`, and a
  # crash anywhere below formats the struct whole into a log line.
  @derive {Inspect, except: [:http_opts, :base_url]}
  @enforce_keys [:chain_ref, :base_url, :network, :source]
  defstruct [
    :chain_ref,
    :base_url,
    :network,
    :source,
    :scope,
    http_opts: [],
    cache?: true
  ]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          base_url: String.t(),
          network: String.t(),
          source: :aztecscan | :chicmoz,
          scope: Scope.t() | nil,
          http_opts: keyword(),
          cache?: boolean()
        }

  @typedoc "The finality ladder, plus the freshness of the view that reported it."
  @type tips :: %{
          proposed: non_neg_integer() | nil,
          checkpointed: non_neg_integer() | nil,
          proven: non_neg_integer() | nil,
          finalized: non_neg_integer() | nil,
          stale?: boolean(),
          staleness_ms: non_neg_integer() | nil,
          degraded?: boolean()
        }

  @typedoc "What identifies an L2: its own network, and its anchor on L1."
  @type rollup :: %{
          network: String.t() | nil,
          l1_chain_id: non_neg_integer() | nil,
          rollup_version: String.t() | nil,
          l1_rollup: Backend.account_ref() | nil,
          l1_registry: Backend.account_ref() | nil
        }

  # Probed 2026-09-14. The key segment is named `temporary-api-key` upstream,
  # so `:temporary_path` is a dated note for a human rather than a gate: the
  # breaker and the 404 classification are what decide reachability at runtime,
  # and a withdrawn prefix has to fail over rather than fail.
  @aztecscan "https://api.aztecscan.xyz/v1/temporary-api-key"

  # The same segment on its own, because `backend/1` reads it off a handle's
  # resolved URL to name the source.
  @temporary_key "temporary-api-key"

  # The network id is the second half of each row because it is checked against
  # the instance's own `l2/info`. A self-hosted fallback aimed at a different
  # network is the failure this catches, and it is the one failure a fallback
  # can have that looks like success.
  @sources %{
    "aztec:mainnet" => {@aztecscan, "MAINNET", :temporary_path}
  }

  # A guess, and labelled as one. Neither Aztecscan nor `chicmoz` publishes a
  # figure, and probing for one would mean deliberately exceeding it on a free
  # path whose name already says it is a favour. It is under the package
  # default (10 at 2/s) rather than over it for that reason.
  @rate_limit [capacity: 5, refill_per_second: 1.0]

  @optional [:get_transaction, :get_block, :contract_metadata]

  @doc """
  Build a handle for an Aztec chain reference.

  `:base_url` points at a self-hosted `chicmoz` instance, scheme and prefix
  included (`"https://chicmoz.example.org/v1/local"`). Omitted, the handle
  talks to the hosted Aztecscan instance on the temporary path. The two are the
  primary and the fallback of the same chain and are built from the same
  module, so a router takes `[primary, fallback]` and needs nothing else.

  `:cache` defaults to `true`; `false` turns the response cache off for this
  handle. A height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, {default_url, network, _status}} <-
           Map.fetch(@sources, chain_ref) |> ok_or({:unsupported_chain, chain_ref}),
         {:ok, base_url, source} <- resolve(default_url, Keyword.get(opts, :base_url)) do
      state = %__MODULE__{
        chain_ref: chain_ref,
        base_url: base_url,
        network: network,
        source: source,
        http_opts: Keyword.put_new(Keyword.get(opts, :http_opts, []), :rate_limit, @rate_limit),
        cache?: Keyword.get(opts, :cache, true)
      }

      state = %{state | scope: Scope.of(base_url, state.http_opts)}

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The chain-to-source table, with its network id and dated status. Data, not behaviour."
  @spec sources() :: %{
          Backend.chain_ref() => {String.t(), String.t(), :temporary_path}
        }
  def sources, do: @sources

  @doc "The rate limit seeded per origin, and a reminder that it is a guess."
  @spec rate_limit() :: keyword()
  def rate_limit, do: @rate_limit

  @impl Backend
  def backend, do: :aztec

  # The per-handle name, because one module carries both sources. `coverage/2`
  # reporting `[:aztec, :aztec]` tells an operator that two sources are
  # believed healthy and not which of them is the temporary path, and during a
  # revocation that is the only question. `backend/0` stays the chain-level
  # name that config and a router's failover order are written against.
  @impl Backend
  def backend(%__MODULE__{source: source}), do: source

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{}), do: @optional

  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, Origin.for_url(state.base_url)}

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with {:ok, info} <- object(get(state, "/l2/info", :chain_stats, :fixed)),
         :ok <- same_network(state, info),
         {:ok, block_time} <- get(state, "/l2/stats/average-block-time", :chain_stats, :fixed),
         {:ok, transactions} <- get(state, "/l2/stats/total-tx-effects", :chain_stats, :fixed),
         {:ok, average_block_time_ms} <- Backend.int(block_time, :average_block_time_ms),
         {:ok, total_transactions} <- Backend.int(transactions, :total_transactions) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         average_block_time_ms: average_block_time_ms,
         # No counter of blocks exists on this surface, and `l2/tips` reports a
         # height. Reading a height as a count is the mistake ADR-0038
         # records, so this stays nil rather than borrowing that number.
         total_blocks: nil,
         # One tx effect per mined transaction, which is the count a caller
         # means. `l2/stats/total-txs` is a 404; the plural that exists is
         # `total-tx-effects`.
         total_transactions: total_transactions,
         # No account resource exists, so no count of accounts does either.
         # `total-contract-instances` (205 on 2026-09-14) counts deployments
         # rather than addresses.
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    with {:ok, body} <- object(get(state, "/l2/tips", nil, :fixed)),
         {:ok, height, finalized} <- ladder(body) do
      {:ok,
       %{
         height: height,
         finalized_height: finalized,
         unit: :block,
         indexer: indexer(body)
       }}
    end
  end

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) when is_binary(hash) do
    with {:ok, segment} <- PathSegment.encode(hash, "hash") do
      case object(get(state, "/l2/tx-effects/#{segment}", :transaction, :addressed)) do
        {:ok, body} -> mined(body)
        {:error, {:upstream_refused, :not_found}} -> pooled(state, segment)
        {:error, _reason} = error -> error
      end
    end
  end

  @impl Backend
  def get_block(%__MODULE__{} = state, number) do
    with {:ok, segment} <- PathSegment.encode(number, "block"),
         {:ok, body} <- object(get(state, "/l2/blocks/#{segment}", :block, :addressed)),
         {:ok, height} <- block_number(body) do
      variables = body |> dig(["header", "globalVariables"]) |> Decode.object()

      {:ok,
       %{
         height: height,
         hash: body["hash"],
         timestamp: timestamp(variables["timestamp"]),
         transactions_count: effect_count(body),
         # An L1 address, 20 bytes, so the EVM tag is the accurate one even
         # inside an Aztec block: the coinbase is who gets paid on L1.
         miner: evm_ref(variables["coinbase"])
       }}
    end
  end

  @impl Backend
  def contract_metadata(%__MODULE__{} = state, account_ref) do
    with {:ok, address} <- aztec_address(account_ref),
         {:ok, segment} <- PathSegment.encode(address, "address"),
         {:ok, body} <-
           object(
             get(
               state,
               "/l2/contract-instances/#{segment}",
               :contract_metadata,
               :addressed
             )
           ) do
      {:ok,
       %{
         name: body["artifactContractName"],
         # Verification is a real concept here (`chicmoz` serves
         # `verify-source` and a `verifiedSourceOnly` filter), and on
         # 2026-09-14 `l2/contract-classes?verifiedSourceOnly=true` answered
         # `[]` and all 23 mainnet instances carried a null `sourceCodeUrl`.
         # So `false` is measured rather than defaulted: it means no source is
         # registered, not that a verification failed.
         verified?: is_binary(body["sourceCodeUrl"]),
         # Not carried. Noir is the only language an Aztec contract is written
         # in, which is exactly why putting it here would be a guess dressed as
         # a reading.
         language: nil,
         compiler_version: nil,
         # `selectorMap` is a selector-to-name map and carries no argument
         # types, so it is not an ABI. An artifact can be requested with
         # `?includeArtifactJson=true`, and no mainnet instance has one to
         # record, so no mapping is written against an unmeasured shape.
         abi: nil,
         proxy_type: nil
       }}
    end
  end

  @doc """
  The finality ladder and the freshness of the view that reported it.

  Outside the contract because `Raxol.Web3.Backend`'s height shape carries one
  finalized number and this chain distinguishes four, and because the staleness
  window `l2/tips` reports is not the indexed-block ratio the `indexer` field
  means. Widening a shape shared by every chain for one chain's ladder is what
  ADR-0033 section 7's "serve a normalized contract" refuses; a named function
  on the backend that has the ladder is the alternative.
  """
  @spec tips(t()) :: {:ok, tips()} | {:error, Backend.error()}
  def tips(%__MODULE__{} = state) do
    with {:ok, body} <- object(get(state, "/l2/tips", nil, :fixed)) do
      ladder = Map.get(body, "tips", %{})

      {:ok,
       %{
         proposed: rung(ladder, "proposed"),
         checkpointed: rung(ladder, "checkpointed"),
         proven: rung(ladder, "proven"),
         finalized: rung(ladder, "finalized"),
         stale?: body["stale"] == true,
         staleness_ms: staleness_ms(body),
         degraded?: body["degraded"] == true
       }}
    end
  end

  @doc """
  What identifies this L2: its own network, and its anchor on L1.

  Outside the contract for the same reason as `tips/1`:
  `Raxol.Web3.Backend`'s `chain_info` shape has no field for an L1 chain id or
  a rollup version, and on an L2 those two are what identify the chain. The
  L1 contract addresses are normalized down to the rollup and the registry
  rather than passed through, because pass-through is what section 7 refuses
  and the other nine addresses identify nothing.
  """
  @spec rollup(t()) :: {:ok, rollup()} | {:error, Backend.error()}
  def rollup(%__MODULE__{} = state) do
    with {:ok, info} <- object(get(state, "/l2/info", :chain_stats, :fixed)),
         {:ok, l1_chain_id} <- Backend.int(info["l1ChainId"], :l1_chain_id) do
      contracts = Map.get(info, "l1ContractAddresses", %{})

      {:ok,
       %{
         network: info["l2NetworkId"],
         l1_chain_id: l1_chain_id,
         rollup_version: info["rollupVersion"],
         l1_rollup: evm_ref(contracts["rollupAddress"]),
         l1_registry: evm_ref(contracts["registryAddress"])
       }}
    end
  end

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. `resource` decides what a 404 means, and it is the endpoint's own
  # shape rather than the response's text that decides it: see the moduledoc.
  #
  # The cache key is the path under the handle's scope, never the assembled
  # URL. On this upstream the credential is a PATH SEGMENT, so the scope
  # (`Raxol.Web3.Scope.id/1` of the whole base URL) is what keeps two key
  # prefixes on one host from sharing entries, and it carries nothing back.
  defp get(state, path, class, resource) do
    url = state.base_url <> path

    url
    |> HTTP.get(Cache.opts(state.http_opts, state.scope, state.cache?, path, class))
    |> decode(resource)
  end

  # Most endpoints answer an object, and the two stats reads answer a bare
  # number or string (`l2/latest-height` does too). Guarding here rather than
  # inside `decode/2` is what lets both kinds share one outbound path.
  defp object({:ok, body}) when is_map(body), do: {:ok, body}
  defp object({:ok, _other}), do: {:error, {:decode_failed, :not_an_object}}
  defp object({:error, _reason} = error), do: error

  # Any JSON term, not only an object: `l2/latest-height` answers a bare
  # number and `l2/stats/average-block-time` a bare string, so requiring an
  # object here would refuse two endpoints for having no wrapper.
  #
  # A non-2xx carries no body onward. ADR-0038 decision 6 keeps upstream text
  # out of an error term, and the 404 classification below needs the endpoint's
  # shape rather than the body: the withdrawn-prefix body is nine bytes of
  # someone else's plain text.
  defp decode({:ok, %{status: status, body: body}}, _resource) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  # `:fixed` is every parameterless endpoint this backend calls, and the list
  # is exhaustive: `/l2/info`, `/l2/tips`, `/l2/stats/average-block-time` and
  # `/l2/stats/total-tx-effects`. None of them takes a parameter, so none of
  # them has a resource that can be absent, so a 404 on one is the prefix
  # being gone rather than the resource. `:addressed` is the other four, which
  # name a block, a transaction hash twice, or a contract instance, and a 404
  # there is an answer.
  #
  # `{:source_unavailable, _}` rather than `{:upstream_refused, :auth}`, which
  # is what this was. Both fail over, which is the routing outcome this split
  # exists for, but `:auth` means "this deployment does not hold the
  # credential" everywhere else in the package (`Raxol.Web3.Backend.Canton`
  # says exactly which key an operator must create), and a withdrawn URL
  # prefix is not a credential we can be handed. Naming it `:auth` to buy a
  # failover made the one classification an operator reads during a
  # revocation say the wrong thing about what to do next.
  defp decode({:ok, %{status: 404}}, :fixed), do: {:error, {:source_unavailable, :endpoint}}
  defp decode({:ok, %{status: 404}}, :addressed), do: {:error, {:upstream_refused, :not_found}}
  defp decode({:ok, %{status: status}}, _resource), do: {:error, {:http, status}}
  defp decode({:error, _reason} = error, _resource), do: error

  # Every caller-supplied id reaches a path through
  # `Raxol.Web3.Backend.PathSegment.encode/2`: encoded against the unreserved set,
  # and refused when it is or decodes into a dot segment. A well-formed id that
  # does not exist is still the upstream's clean 404.

  defp resolve(default_url, nil), do: {:ok, default_url, source(default_url)}

  defp resolve(_default_url, base_url) when is_binary(base_url) do
    url = String.trim_trailing(base_url, "/")
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:invalid_base_url, :scheme}}
      is_nil(uri.host) or uri.host == "" -> {:error, {:invalid_base_url, :host}}
      true -> {:ok, url, source(url)}
    end
  end

  defp resolve(_default_url, _other), do: {:error, {:invalid_base_url, :type}}

  # What names a handle is the credential it presents, not the option it was
  # built from: the segment standing where an API key stands is the withdrawable
  # thing, and a deployment that configures the hosted URL by hand is on the
  # temporary path however it arrived there. `chicmoz` puts its own key in the
  # same position (`/v1/local` on a self-hosted instance), so the two sources
  # are distinguishable by that segment alone.
  defp source(url) do
    path = URI.parse(url).path || ""

    if Path.basename(path) == @temporary_key, do: :aztecscan, else: :chicmoz
  end

  # A self-hosted instance aimed at the wrong network is the one fallback
  # misconfiguration that answers confidently, so it is refused here rather
  # than trusted. `:decode_failed` because the body is not what it claimed to
  # be, and because the router fails over on it: the other source may be
  # pointed at the right chain.
  defp same_network(%__MODULE__{network: network}, %{"l2NetworkId" => network}), do: :ok
  defp same_network(_state, _info), do: {:error, {:decode_failed, :network_mismatch}}

  defp ladder(%{"tips" => %{"proposed" => %{"number" => height}} = tips})
       when is_integer(height) do
    case rung(tips, "finalized") do
      nil -> {:ok, height, nil}
      finalized when finalized <= height -> {:ok, height, finalized}
      _above_the_head -> {:error, {:decode_failed, :tips}}
    end
  end

  defp ladder(_body), do: {:error, {:decode_failed, :tips}}

  # `stalenessMs` is the age of the tips observation, so it is how far behind
  # now this source's view is, in seconds. An indexer that stopped observing
  # shows it growing, which is what makes it a lag rather than a constant.
  defp indexer(body) do
    reported = %{finished?: body["stale"] != true}

    case staleness_ms(body) do
      nil -> reported
      ms -> Map.put(reported, :lag_seconds, div(ms, 1000))
    end
  end

  # `proposed` reports a number directly; the three settled rungs each report a
  # block and the L1 checkpoint that settled it, and it is the block number
  # that is comparable with a height.
  defp rung(%{"proposed" => %{"number" => number}}, "proposed") when is_integer(number),
    do: number

  defp rung(ladder, name) do
    case dig(ladder, [name, "block", "number"]) do
      number when is_integer(number) -> number
      _absent -> nil
    end
  end

  defp mined(body) do
    with {:ok, status} <- revert_status(body["revertCode"]),
         {:ok, fee} <- Backend.money(body["transactionFee"], :fee),
         {:ok, block} <- Backend.int(body["blockHeight"], :block_height) do
      {:ok,
       %{
         hash: body["txHash"],
         status: status,
         block: block,
         timestamp: timestamp(body["timestamp"]),
         from: nil,
         to: nil,
         value: nil,
         fee: fee,
         # A private function call is not observable, and the public call
         # requests a transaction made are a separate resource rather than a
         # name on this record.
         method: nil
       }}
    end
  end

  # `segment` is the hash as `get_transaction/2` already checked and encoded it.
  defp pooled(state, segment) do
    with {:ok, body} <- object(get(state, "/l2/txs/#{segment}", :transaction, :addressed)) do
      {:ok,
       %{
         hash: body["txHash"],
         status: :pending,
         block: nil,
         timestamp: timestamp(body["birthTimestamp"]),
         from: nil,
         to: nil,
         value: nil,
         # The pool record carries gas limits and max fees, which are bounds
         # rather than a fee. What was paid is known once it is mined.
         fee: nil,
         method: nil
       }}
    end
  end

  # A mined effect whose revert code cannot be read is not a transaction whose
  # status is unknown, because the contract has no such status. It is a body
  # that is not what it claimed, and the other source may parse it.
  defp revert_status(%{"code" => code}) do
    case Backend.int(code, :revert_code) do
      {:ok, 0} -> {:ok, :success}
      {:ok, other} when is_integer(other) -> {:ok, :reverted}
      {:ok, nil} -> {:error, {:decode_failed, :revert_code}}
      {:error, _reason} = error -> error
    end
  end

  defp revert_status(_absent), do: {:error, {:decode_failed, :revert_code}}

  defp block_number(body) do
    case Backend.int(body["height"], :block) do
      {:ok, height} when is_integer(height) -> {:ok, height}
      {:ok, nil} -> {:error, {:decode_failed, :block}}
      {:error, _reason} = error -> error
    end
  end

  defp effect_count(body) do
    case dig(body, ["body", "txEffects"]) do
      effects when is_list(effects) -> length(effects)
      _absent -> nil
    end
  end

  defp aztec_address({:aztec, address}) when is_binary(address), do: {:ok, address}
  defp aztec_address({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp aztec_address(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp evm_ref(address) when is_binary(address), do: {:evm, address}
  defp evm_ref(_absent), do: nil

  # The age of the tips observation, in milliseconds, or `nil`.
  #
  # Unreadable is reported the same as absent, which is the one place in this
  # module a malformed value does NOT fail the read. This is a diagnostic:
  # `block_height/1`'s contract is a height, and `indexer` hangs off it to say
  # how fresh the source's view is. Failing the whole read over it threw away
  # a height that parsed, on a REQUIRED callback, because an optional field
  # beside it did not -- and `Raxol.Web3.Router` fails over on
  # `{:decode_failed, _}`, so an upstream shipping one bad `stalenessMs` cost
  # the chain its height on every source at once.
  #
  # Nothing is truncated to buy that: an unreadable age becomes no age, which
  # is what a negative one already became. The rule the rest of this module
  # keeps -- a wrong number is worse than no number -- is what says so.
  defp staleness_ms(body) do
    case Backend.int(body["stalenessMs"], :staleness_ms) do
      {:ok, ms} when is_integer(ms) and ms >= 0 -> ms
      _absent_or_unreadable -> nil
    end
  end

  # Milliseconds since the epoch, which is what every timestamp on this
  # surface is: a block's `globalVariables.timestamp` and a transaction's
  # `birthTimestamp` both read 1789380527000-scale on 2026-09-14.
  defp timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_other), do: nil
end

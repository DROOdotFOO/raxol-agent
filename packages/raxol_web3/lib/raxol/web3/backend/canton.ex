defmodule Raxol.Web3.Backend.Canton do
  @moduledoc """
  The Canton backend, against the Splice Scan v0 surface plus ccscan's MCP tools.

  No addresses (party ids), no blocks (rounds), pagination by POST after-cursor.
  Every read except `raw_request/2` is keyless.

  `:scan_url` carries the path prefix: `api.cantonnodes.com` serves the surface
  under `/v0`, a self-hosted Splice Scan under `/api/scan/v0`. Pointing at an
  operator's own Scan instance is a URL change. ccscan's design is not ported;
  only its public MCP tool surface is used, through `raw_request/2`.

  ## Parties

  `account_info/2` and `token_balances/3` take `{:party, "name::fingerprint"}`.
  On the served surface `"party:Alice::1220abcd"` parses back to
  `{:party, "Alice::1220abcd"}` (the parse splits on the first colon only).

  The account map omits `:kind` (Canton has no account-kind taxonomy);
  `contract?` and `verified?` are always `false`; `name` is the party id's
  self-asserted name component. `resolve_name/2` is not declared: the Canton
  Name Service directory is empty on the public host.

  ## Rounds

  `block_height/1` returns `unit: :round`. `height` is the round whose data the
  source has complete, a lower bound on chain progress. `finalized_height` equals
  it by construction (BFT, no fork choice), so confirmation depth is 0. `indexer`
  reports `finished?: true` and `lag_seconds`. `get_block/2` is not declared.

  ## Pagination

  `token_balances/3` walks `POST /v0/holdings/state` with an integer `after`. A
  non-null `next_page_token` beside an empty page means keep going. The cursor
  pins `migration_id` and `record_time`; an `after` outside the snapshot range is
  a 400, which a caller sees when the daily snapshot rolls over: restart the walk.

  ## Amounts

  Canton Coin has 10 decimals; amounts are integers in the smallest unit.
  `account_info/2` reports the gross holding (`total_coin_holdings`), not net of
  the accrued holding fee. A party with no summary row reports `balance: nil`,
  never `0`.

  `list_transactions/3` is not declared: no source lists by party.
  `get_transaction/2` reads `GET /v0/updates/{update_id}` and returns the update
  id, record time and root exercised choice as `method`; a Daml update has no
  single sender, recipient, value or fee.

  ## ccscan credential

  Pass a free ccscan account key as `:ccscan_key`. Without it, or when ccscan
  answers `account_required`, `raw_request/2` fails `{:upstream_refused, :auth}`.
  The key is composed into a header per call and never logged, cached or
  persisted; `raw_request/2` is never cached.

  ## Rate limits and chain reference

  `canton:global` (not a registered CAIP-2 namespace) names the Global
  Synchronizer; `canton:mainnet` is an alias. Neither upstream publishes limits:
  the refill rate is a guess from an observed ~3-request 429 threshold, and the
  capacity is the four-request cold cost of `token_balances/3`.
  """

  @behaviour Raxol.Web3.Backend

  import Raxol.Web3.Backend.Decode,
    only: [dig: 2, field: 2, int: 1, iso8601: 1, object: 1, ok_or: 3, rows_of: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Canton.Holdings
  alias Raxol.Web3.Backend.Canton.Scan
  alias Raxol.Web3.MCPCall
  alias Raxol.Web3.Origin

  # The struct carries a credential, so it declares what `inspect/1` may show.
  # `Raxol.Agent.ExecutorConfig` is the precedent. It is load-bearing
  # rather than tidy: `Raxol.Web3.Router.candidates/3` hands these handles to
  # an operator, and a `FunctionClauseError` anywhere below formats the whole
  # struct into a crash log, which is how the ccscan key would reach one.
  # `:http_opts` is out for the same reason: it is an operator's own keyword
  # list and may carry an authorization header for an RBAC-gated Scan.
  # Both URLs are out as well: per `Raxol.Web3.Origin`, an operator's Scan
  # host can name an account.
  @derive {Inspect, except: [:http_opts, :scan_url, :ccscan_url, :ccscan_key]}
  @enforce_keys [:chain_ref, :scan_url]
  defstruct [
    :chain_ref,
    :scan_url,
    :ccscan_url,
    :ccscan_key,
    :migration_id,
    ccscan_auth_header: "authorization",
    http_opts: [],
    cache?: true
  ]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          scan_url: String.t(),
          ccscan_url: String.t(),
          ccscan_key: String.t() | nil,
          migration_id: non_neg_integer() | nil,
          ccscan_auth_header: String.t(),
          http_opts: keyword(),
          cache?: boolean()
        }

  @chain_ref "canton:global"

  # Ours, not registered: no CAIP-2 namespace exists for Canton. The alias is
  # here so a caller reaching for the EVM habit still routes.
  @chain_refs %{@chain_ref => @chain_ref, "canton:mainnet" => @chain_ref}

  @default_scan_url "https://api.cantonnodes.com/v0"
  @default_ccscan_url "https://ccscan.xyz/mcp"

  # Measured 2026-09-14: `tools/list` on the ccscan endpoint answers 200 with
  # exactly these 13 names and issues no session. Names only. The upstream's own
  # descriptions are not copied anywhere, which is ADR-0033 section 7's rule
  # about third-party prose and is also what keeps a served tool definition free
  # of em-dashes this repository's prose lint would refuse.
  @ccscan_tools ~w(search get_network_overview get_economics get_price get_assets
                   get_transactions get_transaction get_party get_validators
                   get_sv_locking get_app_locking get_governance get_round)

  @optional_callbacks_declared [:get_transaction, :account_info, :token_balances, :raw_request]

  @doc """
  Build a handle for a Canton chain reference.

  Options:

    * `:scan_url` - the Splice Scan v0 base, prefix included. Defaults to
      `#{@default_scan_url}`, the keyless host. A configured Scan instance is
      `https://<host>/api/scan/v0`.
    * `:ccscan_url` - the ccscan MCP endpoint, default `#{@default_ccscan_url}`.
    * `:ccscan_key` - the ccscan account credential. Without it `raw_request/2`
      refuses with `{:upstream_refused, :auth}` and nothing else changes.
    * `:ccscan_auth_header` - the header the credential travels in, default
      `authorization` with a `Bearer` scheme. **This name is a guess**: the
      upstream's refusal says "or use an API key" without naming a header, and
      the endpoint that would document it is account-gated. An operator who
      knows better overrides it here rather than patching this module.
    * `:migration_id` - pins the synchronizer migration the party-scoped reads
      query. Derived from `/v0/dso` when absent, which is the honest default;
      pass it to read a historical migration deliberately.
    * `:http_opts` - forwarded to `Raxol.Web3.HTTP` unchanged.
    * `:cache` - default `true`. `false` turns off the response cache for this
      handle. A height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, canonical} <-
           Map.fetch(@chain_refs, chain_ref) |> ok_or(chain_ref, &{:unsupported_chain, &1}),
         {:ok, scan_url} <- base_url(opts, :scan_url, @default_scan_url),
         {:ok, ccscan_url} <- base_url(opts, :ccscan_url, @default_ccscan_url) do
      state = %__MODULE__{
        chain_ref: canonical,
        scan_url: scan_url,
        ccscan_url: ccscan_url,
        ccscan_key: Keyword.get(opts, :ccscan_key),
        migration_id: Keyword.get(opts, :migration_id),
        ccscan_auth_header: Keyword.get(opts, :ccscan_auth_header, "authorization"),
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  # Validated at construction: `health_key/1` runs `URI.new!/1` on the Scan
  # base, so a bad URL must fail the handle rather than a router ordering
  # candidates. `Raxol.Web3.HTTP` only dials `https`.
  defp base_url(opts, key, default) do
    case Keyword.get(opts, key, default) do
      url when is_binary(url) -> checked_url(String.trim_trailing(url, "/"), key)
      _other -> {:error, {:invalid_base_url, key}}
    end
  end

  defp checked_url(url, key) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> {:ok, url}
      {:ok, %URI{scheme: "https"}} -> {:error, {:invalid_base_url, :host}}
      {:ok, %URI{}} -> {:error, {:invalid_base_url, :scheme}}
      {:error, _part} -> {:error, {:invalid_base_url, key}}
    end
  end

  @doc "The probed endpoint table, as `{method, path}`. Data, not behaviour."
  @spec paths() :: %{atom() => {:get | :post, String.t()}}
  def paths, do: Scan.paths()

  @doc "The ccscan tool names `raw_request/2` will dispatch."
  @spec raw_request_allowlist() :: [String.t()]
  def raw_request_allowlist, do: @ccscan_tools

  @doc "The chain references this backend answers for, canonical and aliased."
  @spec chain_refs() :: [Backend.chain_ref()]
  def chain_refs, do: Map.keys(@chain_refs)

  @doc """
  The token-bucket seed both upstreams get unless a handle overrides it.

  Data, so the derivation in "Rate limits and chain reference" is checkable
  rather than asserted.
  """
  @spec rate_limit() :: keyword()
  def rate_limit, do: Scan.rate_limit()

  @impl Backend
  def backend, do: :canton

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  # The same list with and without a credential. `raw_request/2` is declared
  # either way so that a missing key is a named, actionable refusal rather than
  # `{:unsupported, :raw_request}`, which would tell an operator that the source
  # cannot answer when in fact it can, with an account.
  @impl Backend
  def capabilities(%__MODULE__{}), do: @optional_callbacks_declared

  # The keyless Scan host, because that is where the two required callbacks go.
  # ccscan is a second origin with its own bucket and breaker inside
  # `Raxol.Web3.HTTP`; a router ordering candidates cares about the origin that
  # answers the reads every source must answer.
  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, Origin.for_url(state.scan_url)}

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with {:ok, body} <- Scan.dso(state) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         # The mining round's tick duration, which is this chain's cadence. It
         # is not a block time, because there are no blocks.
         average_block_time_ms: tick_duration_ms(body),
         # Three nils, and each is a fact rather than a gap: Canton has no
         # blocks to count and no addresses to count, and the keyless surface
         # publishes no chain-wide transaction total.
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    with {:ok, body} <- Scan.get(state, :round_of_latest_data),
         {:ok, round} <- fetch_round(body) do
      {:ok,
       %{
         height: round,
         finalized_height: round,
         unit: :round,
         indexer: indexer(body)
       }}
    end
  end

  @impl Backend
  def get_transaction(%__MODULE__{} = state, update_id) when is_binary(update_id) do
    with {:ok, body} <- Scan.get_update(state, update_id) do
      {:ok, transaction(body)}
    end
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    with {:ok, party} <- party(account_ref),
         {:ok, snapshot} <- Scan.snapshot(state),
         request = Map.put(snapshot, "owner_party_ids", [party]),
         {:ok, body} <- Scan.post(state, :holdings_summary, request, :account) do
      account(party, body)
    end
  end

  @impl Backend
  def token_balances(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, party} <- party(account_ref),
         {:ok, request} <- Holdings.request(state, party, Keyword.get(opts, :cursor)),
         {:ok, symbol} <- Holdings.names(state),
         {:ok, body} <- Scan.post(state, :holdings_state, request, :list) do
      Holdings.page(state, request, body, symbol)
    end
  end

  @doc """
  Dispatch one allowlisted ccscan tool and return its payload.

  The allowlist is `raw_request_allowlist/0`, the 13 read-only tool names
  measured from a live `tools/list`. Arguments must be a flat map of scalars: a
  nested structure is refused here rather than forwarded, because these values
  are the one thing on this path a caller chooses.

  Requires `:ccscan_key`. Without one this is `{:upstream_refused, :auth}` and
  no request is made.
  """
  @impl Backend
  def raw_request(%__MODULE__{ccscan_key: nil}, _call), do: {:error, {:upstream_refused, :auth}}

  def raw_request(%__MODULE__{} = state, %{tool: tool} = call) when is_binary(tool) do
    with :ok <- allowed_tool(tool),
         {:ok, arguments} <- scalar_arguments(Map.get(call, :arguments, %{})) do
      state.ccscan_url
      |> MCPCall.call(tool, arguments, ccscan_opts(state))
      |> ccscan_result()
    end
  end

  def raw_request(%__MODULE__{}, _call), do: {:error, {:unsupported, :raw_request}}

  # The credential is composed into a header here, per call, and nowhere else.
  # It is not in the cache options, because `raw_request/2` is not cached, and
  # it is not in any error term, because none of them carries a header.
  # `Backend.put_header/2` rather than a `Keyword.put`, so an operator's own
  # headers reach an RBAC-gated instance instead of being dropped.
  defp ccscan_opts(state) do
    state.http_opts
    |> Keyword.put_new(:rate_limit, Scan.rate_limit())
    |> Backend.put_header({state.ccscan_auth_header, "Bearer " <> state.ccscan_key})
  end

  # The one recognised body shape this backend declares. `account_required` was
  # measured 2026-09-14 inside an HTTP 200 with `isError: true`, so it is mapped
  # from the body and never from a status. The payload is dropped rather than
  # carried: ADR-0038 decision 6 keeps upstream text out of an error term, and
  # the actionable part is in this module's moduledoc instead.
  defp ccscan_result({:ok, payload}), do: {:ok, payload}

  defp ccscan_result({:tool_error, %{"error" => "account_required"}}) do
    {:error, {:upstream_refused, :auth}}
  end

  defp ccscan_result({:tool_error, _payload}), do: {:error, {:upstream_refused, :unknown}}
  defp ccscan_result({:error, _reason} = error), do: error

  defp allowed_tool(tool) do
    if tool in @ccscan_tools, do: :ok, else: {:error, {:unsupported, :raw_request}}
  end

  defp scalar_arguments(arguments) when is_map(arguments) do
    if Enum.all?(arguments, &scalar_argument?/1) do
      {:ok, Map.new(arguments, fn {key, value} -> {to_string(key), value} end)}
    else
      {:error, {:unsupported, :raw_request}}
    end
  end

  defp scalar_arguments(_other), do: {:error, {:unsupported, :raw_request}}

  defp scalar_argument?({key, value}) do
    (is_binary(key) or is_atom(key)) and
      (is_binary(value) or is_number(value) or is_boolean(value))
  end

  defp tick_duration_ms(body) do
    case dig(body, ["latest_mining_round", "contract", "payload", "tickDuration"]) do
      %{"microseconds" => micros} -> div_or_nil(int(micros), 1000)
      _absent -> nil
    end
  end

  defp div_or_nil(nil, _divisor), do: nil
  defp div_or_nil(value, divisor), do: div(value, divisor)

  defp account(party, body) do
    summary = body |> field("summaries") |> rows_of() |> List.first()

    {:ok,
     %{
       ref: {:party, party},
       # `nil` and not `0` for an absent summary: see the moduledoc.
       balance: summary && Holdings.amulet(field(summary, "total_coin_holdings")),
       # A party holds no code and there is nothing to verify.
       contract?: false,
       verified?: false,
       # Self-asserted by whoever allocated the party, and not unique.
       name: party_name(party),
       ens: nil
       # `:kind` is omitted, not nil: Canton has no account-kind taxonomy.
     }}
  end

  # Thin on purpose: a Daml update carries no single sender, recipient, value or
  # fee. `method` is the root exercised choice, which is the operation invoked.
  defp transaction(body) do
    %{
      hash: body["update_id"],
      # An update in the Scan's history is a committed transaction. A rejected
      # Canton command never becomes one, so there is no reverted state to
      # report and `:pending` cannot be observed from this endpoint either.
      status: :success,
      block: nil,
      timestamp: iso8601(body["record_time"]),
      from: nil,
      to: nil,
      value: nil,
      fee: nil,
      method: root_choice(body)
    }
  end

  defp root_choice(body) do
    events = body |> field("events_by_id") |> object()

    body
    |> field("root_event_ids")
    |> rows_of()
    |> Enum.find_value(fn id -> exercised_choice(field(events, id)) end)
  end

  defp exercised_choice(%{"event_type" => "exercised_event", "choice" => choice})
       when is_binary(choice),
       do: choice

  defp exercised_choice(_event), do: nil

  # `finished?` is the endpoint's own claim: it is named for the round whose
  # data is complete. `lag_seconds` is the age of that data, which is the one
  # freshness figure this host publishes. No ratio is published and there are no
  # blocks to lag by, so both of those keys are absent rather than computed.
  defp indexer(%{"effectiveAt" => effective_at}) when is_binary(effective_at) do
    case iso8601(effective_at) do
      nil -> %{finished?: true}
      datetime -> %{finished?: true, lag_seconds: max(0, DateTime.diff(utc_now(), datetime))}
    end
  end

  defp indexer(_body), do: %{finished?: true}

  defp utc_now, do: DateTime.utc_now()

  defp fetch_round(%{"round" => round}) do
    case int(round) do
      nil -> {:error, {:decode_failed, :round}}
      value -> {:ok, value}
    end
  end

  defp fetch_round(_body), do: {:error, {:decode_failed, :round}}

  # A party id is `name::fingerprint`, so the name is the part before the first
  # pair of colons. A party id with no name part reports `nil` rather than "".
  defp party_name(party) do
    case String.split(party, "::", parts: 2) do
      [name, _fingerprint] when name != "" -> name
      _unnamed -> nil
    end
  end

  # A party id travels in a JSON request body, and `Jason.encode!/1` RAISES on
  # a binary that is not valid UTF-8, so the charset is checked here, on the
  # function that composes the request, rather than left to the encoder.
  defp party({:party, id}) when is_binary(id) and id != "" do
    if String.valid?(id), do: {:ok, id}, else: {:error, {:unsupported_account_ref, :party}}
  end

  defp party({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp party(_other), do: {:error, {:unsupported_account_ref, :unknown}}
end

defmodule Raxol.Web3.Backend.Canton do
  @moduledoc """
  The Canton backend, against the Splice Scan v0 surface plus ccscan's MCP tools.

  This is the chain that three of `Raxol.Web3.Backend`'s shapes exist for, so
  each one is exercised here rather than asserted: there are no addresses, only
  party ids; there are no blocks, only rounds; and pagination is a POST carrying
  an after-cursor, which is a fourth scheme beside Blockscout's keyset, a
  `start`/`limit` ceiling and a signature cursor.

  ## What answers without a credential

  Measured 2026-09-14, every read this backend declares except `raw_request/2`
  answers keyless:

    * `GET /v0/round-of-latest-data` answers 200 with no credential, carrying
      `{"round": 113141, "effectiveAt": "2026-09-14T10:39:37Z"}`.
    * `GET /v0/dso` answers 200 with no credential, 72,339 bytes, carrying
      `dso_party_id`, the voting threshold, the latest mining round and every
      super-validator's declared synchronizer migration id.
    * `POST /v0/holdings/summary` and `POST /v0/holdings/state` both answer 200
      with no credential for a real party id, which means the **party-scoped**
      reads are keyless too and not only the two required callbacks.
    * `GET /v0/updates/{update_id}` answers 200 with no credential.

  The ccscan account is needed only for the passthrough.

  Two path guesses from the Splice specification were wrong on the same host,
  which is why the table below is probe-derived rather than ported:
  `/v0/total-amulet-balance?asOfEndOfRound=N` is a 404, and `/v0/acs/{party}` is
  a 404. `POST /v0/holdings/summary` rejects `party_ids` and requires
  `owner_party_ids`, which a specification reader would not guess either.

  ## Two hosts, one surface, one prefix that moves

  `api.cantonnodes.com` serves the Splice Scan v0 surface under `/v0`. A
  configured Splice Scan instance serves the same surface under `/api/scan/v0`:
  measured 2026-09-14, `scan.sv-1.global.canton.network.digitalasset.com` answers
  403 `RBAC: access denied` for `/api/scan/v0/dso`, which is an authorization
  refusal rather than a 404, so the prefix is right and that particular host is
  not open from this network. The prefix therefore travels inside `:scan_url`
  rather than being hardcoded, and pointing this backend at an operator's own
  Scan instance is a URL change and no code change.

  Splice Scan is Apache-2.0 and publishes an OpenAPI specification, which is the
  licence that permits reuse. ccscan is closed and governed by its terms of
  service, so its **design is not ported**: what is used from it is its public
  MCP tool surface, through `raw_request/2`, and nothing else.

  ## No addresses: a party id

  `account_info/2` and `token_balances/3` take `{:party, "name::fingerprint"}`.
  A party id is a name, two colons and a fingerprint, and it is
  `Raxol.Web3.Serialize`'s `party` tag that carries it across the served
  surface: `"party:Alice::1220abcd"` parses back to `{:party, "Alice::1220abcd"}`
  because that parse splits on the FIRST colon only.

  The `::` never needs URL escaping here, because every party-scoped read this
  backend uses is a POST whose party travels in the body. The one keyless GET
  that takes a party in its path, `/v0/ans-entries/by-party/{party}`, takes it
  unescaped without complaint and answered a structured 404 echoing the party
  back for every party probed on 2026-09-14, so the Canton Name Service
  directory is empty on this host and `resolve_name/2` is not declared: a read
  whose only observed answer is a refusal is not a read.

  `:kind` is **omitted** from the account map rather than set. Canton has no
  account-kind taxonomy that changes how a balance must be read: every party is
  a party, and the distinctions that exist (a super-validator, a validator, an
  end user) are roles in governance rather than in custody. An absent key means
  the question does not apply here, which is a different fact from `nil`.

  `contract?` and `verified?` are both `false` by construction: a party holds no
  code and there is no source-verification notion to report. `name` is the party
  id's own name component, which is self-asserted by whoever allocated the
  party and is not unique, exactly as an explorer's address label is.

  ## No blocks: a round, and what the two heights mean

  `block_height/1` returns `unit: :round`, and neither number is a height in the
  EVM sense. `GET /v0/round-of-latest-data` names the round whose data the
  source has complete, so:

    * `height` is that round. It is a **lower bound on chain progress** rather
      than a tip: the open mining rounds run ahead of it, and this keyless
      surface publishes no tip round.
    * `finalized_height` is the **same number, deliberately and not by
      omission**. Canton commits through BFT consensus with no fork choice, so a
      round whose data is complete cannot be reorganized. The pair is equal by
      construction, a consumer's confirmation depth is 0, and 0 is the true
      answer on this chain rather than an absence to be reported as `nil`.

  `indexer` reports `finished?: true`, which is the endpoint's own claim and not
  ours (it is named for the round whose data is complete), plus `lag_seconds`
  from the age of the `effectiveAt` the same response carries. `:indexed_ratio`
  and `:lag_blocks` are omitted: no ratio is published, and there are no blocks
  to lag by.

  `get_block/2` is **not declared**, so `Raxol.Web3.Router.coverage/2` reports
  its absence for this chain. None of the Splice Scan paths returns a block,
  because there is none to return.

  ## A POST with an after-cursor

  `POST /v0/holdings/state` is the fourth pagination scheme in this package.
  Measured 2026-09-14 and every part of it measured rather than read:

    * the request carries `after`, an integer offset into the ACS snapshot,
      beside `migration_id`, `record_time`, `owner_party_ids` and `page_size`;
    * the response carries `next_page_token`, an integer or `null`;
    * `after: 8926540676` returned `next_page_token: 8926540890`, so the walk
      advances, while the plausible `page_token` name is silently ignored;
    * an `after` outside the snapshot range is a 400 carrying the range, which
      is what a caller sees when the daily snapshot rolls over mid-walk: restart
      the walk;
    * **a non-null `next_page_token` beside an EMPTY `created_events` means keep
      going, not done.** The scan pages through the snapshot and a page can
      filter to nothing. So `next` is minted from the token's presence and never
      from whether the page had items.

  The cursor carries `migration_id` and `record_time` alongside `after`, because
  an offset into one snapshot is meaningless in another, and pinning them is
  what makes a held cursor keep walking the snapshot it was minted against.

  ## Amounts, and the fee this backend does not net out

  Canton Coin carries exactly 10 decimal places in every figure of every
  response probed, so an amount is reported in the smallest unit as an integer,
  the way wei and lamports are.

  `account_info/2` reports `total_coin_holdings`, the gross holding. Measured
  2026-09-14, a party's gross total equalled its single Amulet contract's
  `initialAmount` to the digit, so the gross figure and the sum of a
  `token_balances/3` page agree, which is the property that matters when both
  are read together. The upstream publishes an accrued holding fee separately
  (`accumulated_holding_fees_total`, 0.0122197152 against a 1,844,175 holding),
  and neither field here nets it out; a caller needing the spendable figure
  wants `total_available_coin`, which this contract has nowhere to put.

  A party with no summary row reports `balance: nil` rather than `0`. The two
  are indistinguishable in the response, and ADR-0039's rule is that no gate may
  read a non-answer as zero.

  ## `list_transactions/3` is not declared, and that is a measurement

  No probed source lists transactions by party. `POST /v0/transactions`
  answers 200 keyless and is chain-wide, taking only `page_end_event_id`,
  `sort_order` and `page_size`; `POST /v0/updates` is chain-wide too; and
  ccscan's `get_transactions` takes only a `limit`. `get_transaction/2` is
  answerable, from `GET /v0/updates/{update_id}`, and its normalization is thin
  on purpose: a Daml update has no single sender, recipient, value or fee, since
  those live inside per-template choice arguments, and extracting them would be
  a Daml interpreter rather than a normalization. What travels is the update id,
  the record time, and the root exercised choice as `method`.

  ## The ccscan account requirement

  ccscan's `tools/list` is open and stateless: 13 tools, plain
  `application/json`, no session at all. Every `tools/call` answers **HTTP 200**
  with `result.isError: true` and `content[0].text` holding
  `{"error": "account_required", ...}`. That recognised body shape maps onto
  `{:upstream_refused, :auth}`, and the upstream's own sentence does not travel:
  the actionable part is here, in this moduledoc, and in the origin id the error
  path names. **What an operator must do: create a free ccscan account and pass
  its key as `:ccscan_key`.** Nothing else in this backend needs it.

  A handle with no `:ccscan_key` fails `raw_request/2` with the same
  `{:upstream_refused, :auth}` without spending a request, so the answer is the
  named one whether the credential is missing or rejected. It is never the
  reason a required callback fails, because those go to the keyless host.

  The key is held in transit only: it is composed into a request header per call
  and appears in no log line, no telemetry measurement, no cache key and no
  durable store. `raw_request/2` is not cached at all, since a passthrough's
  cache key would have to be composed from caller-supplied arguments.

  ## Chain reference

  There is no registered CAIP-2 namespace for Canton, so `canton:global` is
  **ours rather than registered**, naming the Global Synchronizer.
  `canton:mainnet` is accepted as an alias and normalized to it, so a caller
  that reached for the EVM habit still routes.

  ## Rate limits

  Neither upstream publishes a figure. `api.cantonnodes.com` answered 429 after
  roughly three requests spaced a few seconds apart on 2026-09-14, and answered
  every request spaced twelve seconds apart, so the refill rate in `rate_limit/0` is **a
  guess anchored on that observed threshold** rather than a published number.
  ccscan's limits are **unverified**, because the endpoint that would document
  them is itself account-gated, so it gets the same conservative seed.

  The capacity is not a guess: it is the cold cost of the most expensive single
  read here. `token_balances/3` with nothing cached is four requests, the DSO
  body, the ACS snapshot, the asset catalog and the page itself, so a capacity
  below four would make one logical read fail on its own budget. Three of those
  four are `:catalog`-cached for an hour, so the steady-state cost is one.
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

  Data, so the derivation in "Rate limits" is checkable rather than asserted.
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

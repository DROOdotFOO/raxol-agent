defmodule Raxol.Web3.HTTP do
  @moduledoc """
  The guarded outbound client: the only way out of this package.

  ADR-0038 decision 2. The pipeline is fixed and ordered:

      vet (Outbound) -> cache -> circuit breaker -> token bucket -> pinned dial -> bounded read -> redact

  A backend that calls `Raxol.Web3.Dial` or `Raxol.Web3.Exchange` directly is a
  defect: it skips the vet, the budget and the health record.

    * **vet** refuses a non-https scheme and any target resolving into the reject
      set.
    * **circuit breaker**, keyed per origin, runs BEFORE the bucket so a refused
      call does not spend a token.
    * **token bucket** refuses with `{:rate_limited, ms}` rather than sleeping,
      so a caller with a second source can fail over.
    * **pinned dial** connects to a vetted address with the hostname carrying
      identity.
    * **bounded read** owns the size ceiling, deadline and chunk timeout.
    * **redaction**: no upstream body, query string or caller-influenced host
      leaves this module.

  ## Errors

      {:blocked, reason} | {:dns_failed, origin_id} | {:rate_limited, retry_after_ms}
      | {:breaker_open, origin_id} | {:too_large, limit}
      | {:timeout, :connect | :chunk | :deadline} | {:transport, atom()}

  Any HTTP status is returned as a response, never `{:http, status}`: whether a
  403 is a challenge or a 200 an auth failure is each backend's judgement, and
  the router needs a challenge body intact to classify it.

  ## Health

  `403`, `408`, `429`, any `5xx`, a transport error or a timeout records a breaker
  failure. Everything else, `404` included, records a success. `{:too_large, _}`
  records neither: it is our refusal, not evidence about the upstream.

  ## Time budget

  `request/3` returns within `:budget_ms` (30 s default). One deadline is taken
  at entry and every stage is clamped to what is left: resolution gets
  `min(5s, remaining)`, the dial gets the remainder as `Raxol.Web3.Dial`'s
  `:budget_ms`, and the bounded read's `:deadline_ms` is clamped too. The only
  overshoot is the bounded read's last chunk wait, which
  `Raxol.MCP.BoundedExchange` bounds. This matters because `Raxol.MCP.Server`
  runs tool callbacks with an `:infinity` call timeout.

  ## Headers

  `user-agent` is always `raxol_web3/<version> (+https://raxol.io)`; a supplied
  one is dropped (Mint would otherwise send its own). `accept-encoding: identity`
  is a default a backend may override, since the bounded read does not
  decompress.
  """

  require Logger

  alias Raxol.Core.Outbound
  alias Raxol.Core.TokenBucket
  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Cache
  alias Raxol.Web3.Dial
  alias Raxol.Web3.Exchange
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Redact
  alias Raxol.Web3.Tables

  @version Mix.Project.config()[:version]
  @user_agent "raxol_web3/#{@version} (+https://raxol.io)"

  # A guess, and labelled as one per ADR-0038's mitigation list. No upstream
  # this package targets publishes a figure except Etherscan (3 calls/second,
  # measured), so a backend that knows better passes `:rate_limit`.
  @default_capacity 10
  @default_refill_per_second 2.0

  @default_connect_timeout_ms 5_000

  # The whole wall-clock cost of one guarded request, and the number the
  # moduledoc's "Time budget" states. Every stage below is
  # clamped to what is left of it.
  @default_budget_ms 30_000

  # What resolution may take out of the budget. Bounded separately because a
  # name that never answers must not be able to spend the dial's and the
  # read's share of it.
  @default_resolve_ms 5_000

  # `Raxol.MCP.BoundedExchange`'s own default, repeated here because the
  # clamp has to compare against the value that stage would otherwise use.
  # A stale copy can only make this module's deadline SMALLER than the read's,
  # which is the safe direction.
  @default_deadline_ms 20_000

  @unhealthy_statuses [403, 408, 429]

  @type response :: %{
          status: Mint.Types.status(),
          headers: Mint.Types.headers(),
          body: binary(),
          origin_id: Origin.id()
        }

  @type reason ::
          {:blocked, atom()}
          | {:dns_failed, Origin.id()}
          | {:rate_limited, non_neg_integer()}
          | {:breaker_open, Origin.id()}
          | {:too_large, pos_integer()}
          | {:timeout, :connect | :chunk | :deadline}
          | {:transport, atom()}

  @doc "A guarded GET."
  @spec get(String.t(), keyword()) :: {:ok, response()} | {:error, reason()}
  def get(url, opts \\ []), do: request("GET", url, opts)

  @doc "A guarded POST, for the JSON-RPC readers."
  @spec post(String.t(), iodata(), keyword()) :: {:ok, response()} | {:error, reason()}
  def post(url, body, opts \\ []), do: request("POST", url, Keyword.put(opts, :body, body))

  @doc """
  Run one guarded request.

  Options:

    * `:headers` - request headers. `user-agent` is dropped and replaced.
    * `:body` - request body, default none.
    * `:rate_limit` - `[capacity:, refill_per_second:]` for this origin's bucket.
    * `:breaker` - `[failure_threshold:, recovery_ms:]`.
    * `:cache` - `[key:, ttl_ms:, cacheable:]`. `:key` is the fragment half of
      the `{origin_id, fragment}` entry key (for a backend, `{scope, key}`;
      see `Raxol.Web3.Cache`) and `:ttl_ms` its lifetime.
      `:cacheable` is optional, a `(response -> boolean())` predicate that
      decides whether a 2xx response is a success at the PAYLOAD level; see
      `store/3`'s comment for why a status is not enough on its own.
    * `:budget_ms` - the end-to-end deadline for this call, default `30_000`.
      Resolution, the dial and the read are each clamped to what is left of
      it; see "Time budget".
    * `:connect_timeout_ms`, `:deadline_ms`, `:chunk_timeout_ms`, `:max_bytes`.
      The first two are ceilings, not guarantees: the budget clamps both.
    * `:exchange` - the dial-and-read stage, as
      `(vetted, request, opts -> {:ok, response} | {:error, reason})`. The seam
      exists because the stages before it cannot be exercised against a real
      socket: a local endpoint listens on loopback, which the vet refuses. It
      replaces no behaviour of this module. The options it receives carry
      `:connect_timeout_ms` and `:deadline_ms` already clamped to the budget,
      plus the `:dial_budget_ms` the whole address list shares.

    * `:resolver` - forwarded to `Raxol.Core.Outbound.vet/2`, which documents
      it. The scheme is not forwarded and is always `[:https]`.

  `:transport_opts` is deliberately NOT an option. TLS options belong to the
  dial, which refuses the six that would weaken a handshake, and an option
  passed through here would be one more place to look for a `verify: :verify_none`.

  Every option here is package-internal: they come from a backend module, never
  from a caller-supplied map, an MCP tool argument or a model. `:resolver` and
  `:exchange` in particular are trusted by construction, so nothing that
  crosses the served surface may reach this keyword list.
  """
  @spec request(String.t(), String.t(), keyword()) :: {:ok, response()} | {:error, reason()}
  def request(method, url, opts \\ []) do
    deadline = now_ms() + Keyword.get(opts, :budget_ms, @default_budget_ms)

    vet_opts =
      [schemes: [:https], timeout_ms: min(@default_resolve_ms, remaining(deadline))] ++
        Keyword.take(opts, [:resolver])

    case Outbound.vet(url, vet_opts) do
      {:ok, vetted} -> guarded(method, vetted, deadline, opts)
      {:error, reason} -> {:error, vet_error(reason, url, opts)}
    end
  end

  defp guarded(method, vetted, deadline, opts) do
    origin_id = Origin.id(vetted.uri)

    case cached(origin_id, opts) do
      {:ok, response} ->
        {:ok, Map.put(response, :origin_id, origin_id)}

      :miss ->
        # The breaker before the bucket. A call the breaker refuses opens no
        # socket and so costs the upstream nothing, and spending a token on it
        # first drains the bucket of an origin we are not even talking to:
        # while the breaker is open every refusal ate a token, and the first
        # call after it half-opened was answered `{:rate_limited, ms}` instead
        # of probing. The bucket exists to spend the upstream's budget, not
        # ours, and this is what that sentence implies about the order.
        with :ok <- check_breaker(origin_id, opts),
             :ok <- take_token(origin_id, opts) do
          vetted
          |> exchange(method, deadline, opts)
          |> record_health(origin_id, opts)
          |> store(origin_id, opts)
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp remaining(deadline), do: max(deadline - now_ms(), 0)

  # After the vet and before the bucket, and both halves of that matter. Before
  # the vet, a cache hit would answer for a target we had not checked, so a
  # host that resolved into the reject set since the entry was written would
  # still be served. After the bucket, a hit would spend a token from somebody
  # else's budget for a request we are not making, which defeats the point of
  # caching a free-tier upstream at all.
  #
  # The key is `{origin_id, fragment}`, and the fragment comes from the caller
  # (a backend's carries its scope; see `Raxol.Web3.Cache`).
  # The request URI is never an input: an API key travels as a query parameter
  # on one of the upstreams this package targets, and ADR-0033 section 7 names
  # cache keys as one of the four places a credential leaks.
  defp cached(origin_id, opts) do
    case cache_spec(opts) do
      nil -> :miss
      {fragment, _ttl, _predicate} -> Cache.get({origin_id, fragment})
    end
  end

  # Only a success is stored, and a 2xx is not by itself one. A 404 is a real
  # answer but a cheap one to re-ask, and caching a 403 challenge page would
  # outlive the breaker that is supposed to route around it.
  #
  # The status rule alone was a bug, because every JSON-RPC node and every MCP
  # tool server this package talks to delivers its refusals INSIDE a 200:
  # `error.code -32005` for a rate limit, `-32004` for a block it does not
  # have, `isError: true` for a tool result. The backend classifies those
  # after this stage has already written them, and a cached refusal outlives
  # the condition that produced it by the whole TTL: the `:catalog` class is
  # an hour, so one transient tool error answered every read on that source
  # for an hour while the source itself was healthy.
  #
  # Which bodies are refusals is the caller's judgement and not this module's
  # -- ADR-0038 decision 9 puts a body's meaning in the backend -- so the
  # caller supplies `:cacheable` and this stage consults it. A caller that
  # supplies none keeps the status rule, which is the right one for a REST
  # upstream that announces a refusal with a status.
  defp store({:ok, response} = result, origin_id, opts) do
    with {fragment, ttl, predicate} <- cache_spec(opts),
         true <- response.status in 200..299,
         true <- cacheable?(predicate, response) do
      Cache.put({origin_id, fragment}, Map.delete(response, :origin_id), ttl)
    end

    result
  end

  defp store(result, _origin_id, _opts), do: result

  defp cacheable?(nil, _response), do: true
  defp cacheable?(predicate, response), do: predicate.(response) == true

  defp cache_spec(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        nil

      spec ->
        {Keyword.fetch!(spec, :key), Keyword.fetch!(spec, :ttl_ms), Keyword.get(spec, :cacheable)}
    end
  end

  # A refused target names no host. `:invalid_url` covers both a malformed URL
  # and an `http://` one, which is the same answer to a caller: this is not a
  # target we will dial.
  defp vet_error(:invalid_url, _url, _opts), do: {:blocked, :invalid_url}
  defp vet_error({:blocked_address, _host}, _url, _opts), do: {:blocked, :address}

  # No DNS failure records against the origin's health, for either reason, and
  # the reason is not what decides that -- the pipeline order is.
  #
  # `check_breaker/2` is called from `guarded/4`, which this function's caller
  # never reaches: the vet is stage 1 and a failed vet returns here instead.
  # So a recorded failure cannot spare the NEXT caller anything, because that
  # caller's vet runs first and pays the same resolution budget whatever the
  # breaker says. Recording it would only quarantine an origin for
  # `recovery_ms` at the instant resolution recovered.
  #
  # A name that does not resolve is still a failure and still fails over:
  # `Raxol.Web3.Router` fails over on `{:dns_failed, _}` without consulting
  # any breaker. That is the whole of the routing benefit the record was
  # credited with. Bounding the cost of a broken resolver is a real problem
  # and a separate one; it needs a gate BEFORE the vet, which this is not.
  #
  # One clause, matching any `t:Raxol.Core.Outbound.dns_reason/0` including one
  # added later. This module's taxonomy is closed, and a `FunctionClauseError`
  # on an unrecognised reason is not closed -- that is the failure this
  # package just spent a PR removing from `ToolConverter.public_error/2`.
  defp vet_error({:dns_failed, {_host, reason}}, url, _opts) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        origin_id = Origin.id(uri)

        # Logged rather than swallowed: the returned taxonomy names an origin
        # and nothing else, so this is the only place the reason survives.
        Logger.debug(fn ->
          "raxol_web3: DNS for origin #{origin_id} failed (#{inspect(reason)}); " <>
            "not recorded against the origin's health"
        end)

        {:dns_failed, origin_id}

      _unparseable ->
        {:blocked, :invalid_url}
    end
  end

  defp take_token(origin_id, opts) do
    limit = rate_limit(opts)

    case TokenBucket.take(Tables.buckets(), origin_id, limit) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited} ->
        {:error, {:rate_limited, TokenBucket.retry_after(Tables.buckets(), origin_id, limit)}}
    end
  end

  defp rate_limit(opts) do
    opts
    |> Keyword.get(:rate_limit, [])
    |> Keyword.put_new(:capacity, @default_capacity)
    |> Keyword.put_new(:refill_per_second, @default_refill_per_second)
  end

  defp check_breaker(origin_id, opts) do
    case CircuitBreaker.check(Tables.breakers(), {:origin, origin_id}, breaker_opts(opts)) do
      :open ->
        Logger.debug(fn -> "raxol_web3: breaker open for origin #{origin_id}" end)
        {:error, {:breaker_open, origin_id}}

      state when state in [:closed, :half_open] ->
        :ok
    end
  end

  defp breaker_opts(opts), do: Keyword.get(opts, :breaker, [])

  defp exchange(vetted, method, deadline, opts) do
    stage = Keyword.get(opts, :exchange, &dial_and_read/3)
    stage.(vetted, request_spec(method, vetted, opts), budgeted(opts, deadline))
  end

  # One deadline, clamped into each bound the stage below reads: the dial's
  # total across every candidate address, its per-attempt timeout, and the
  # read's deadline. Whatever a backend asked for, none of them can outlive
  # the budget computed at entry, and a backend that asked for less keeps it.
  defp budgeted(opts, deadline) do
    left = remaining(deadline)

    opts
    |> Keyword.put(:dial_budget_ms, left)
    |> Keyword.put(:connect_timeout_ms, min(connect_timeout_ms(opts), left))
    |> Keyword.put(:deadline_ms, min(deadline_ms(opts), left))
  end

  defp connect_timeout_ms(opts),
    do: Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)

  defp deadline_ms(opts), do: Keyword.get(opts, :deadline_ms, @default_deadline_ms)

  defp dial_and_read(vetted, request, opts) do
    connect_opts = [
      port: vetted.uri.port,
      timeout: connect_timeout_ms(opts),
      budget_ms: Keyword.get(opts, :dial_budget_ms, :infinity)
    ]

    case Dial.connect(vetted.addresses, vetted.hostname, connect_opts) do
      {:ok, conn} -> Exchange.run(conn, request, exchange_opts(opts))
      {:error, reason} -> {:error, dial_error(reason)}
    end
  end

  defp exchange_opts(opts) do
    Keyword.take(opts, [:max_bytes, :deadline_ms, :chunk_timeout_ms])
  end

  defp request_spec(method, vetted, opts) do
    %{
      method: method,
      path: path(vetted.uri),
      headers: headers(opts),
      body: Keyword.get(opts, :body)
    }
  end

  defp path(%URI{path: path, query: nil}), do: path || "/"
  defp path(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp headers(opts) do
    supplied =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.reject(fn {name, _value} -> String.downcase(name) == "user-agent" end)

    [{"user-agent", @user_agent} | put_new_header(supplied, "accept-encoding", "identity")]
  end

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {n, _v} -> String.downcase(n) == name end),
      do: headers,
      else: [{name, value} | headers]
  end

  # Every address was tried and every one failed. A list of nothing but
  # timeouts is a connect timeout; anything else reports the last attempt's
  # reason, collapsed to an atom.
  defp dial_error({:dial_failed, failures}) do
    reasons = Enum.map(failures, fn {_address, reason} -> Redact.reason(reason) end)

    if Enum.all?(reasons, &(&1 == :timeout)),
      do: {:timeout, :connect},
      else: {:transport, List.last(reasons)}
  end

  defp dial_error(:no_addresses), do: {:blocked, :no_address}
  defp dial_error({:not_an_address, _value}), do: {:blocked, :not_an_address}
  defp dial_error({:forbidden_transport_opts, _keys}), do: {:blocked, :forbidden_transport_opts}

  # The budget ran out with addresses still untried. It is a deadline rather
  # than a connect timeout: the attempts that did happen may each have been
  # well inside `:connect_timeout_ms`.
  defp dial_error({:budget_exhausted, _failures}), do: {:timeout, :deadline}

  defp record_health({:ok, response}, origin_id, opts) do
    if unhealthy_status?(response.status),
      do:
        CircuitBreaker.record_failure(Tables.breakers(), {:origin, origin_id}, breaker_opts(opts)),
      else: CircuitBreaker.record_success(Tables.breakers(), {:origin, origin_id})

    {:ok, Map.put(response, :origin_id, origin_id)}
  end

  defp record_health({:error, {:too_large, _limit} = reason}, _origin_id, _opts) do
    {:error, reason}
  end

  defp record_health({:error, reason}, origin_id, opts) do
    CircuitBreaker.record_failure(Tables.breakers(), {:origin, origin_id}, breaker_opts(opts))
    {:error, redact(reason)}
  end

  # Redaction belongs on every path out of this module, not only on the dial's.
  # A mid-read failure arrives from `Raxol.MCP.BoundedExchange` as
  # `{:transport, %Mint.TransportError{}}` or a `%Mint.HTTPError{}`, and
  # passing that through made `@type reason`'s `{:transport, atom()}` false:
  # a reset during the body rendered as `%{code: "error", detail: nil}` while
  # the same reset at dial time rendered `%{code: "transport", detail:
  # :closed}`, and `Raxol.Web3.Router.log_failover/3` `inspect`s the reason,
  # so Mint's `{:invalid_request_target, "/p?apikey=..."}` put a query string
  # in a log line.
  # Anything this does not recognise collapses to `{:transport,
  # :transport_error}` rather than travelling on: a shape nobody enumerated is
  # exactly the shape that carries text.
  defp redact({:transport, reason}), do: {:transport, Redact.reason(reason)}

  defp redact({:timeout, stage} = reason) when stage in [:connect, :chunk, :deadline],
    do: reason

  defp redact(other), do: {:transport, Redact.reason(other)}

  @doc """
  Whether a status is evidence that the ORIGIN is unwell.

  Public because it is the policy and three places need the same line drawn:
  this module records a breaker failure for it, `Raxol.Web3.Router` fails over
  on it, and `Raxol.Web3.MCP.Tools` counts it against the tool's breaker.
  Written out three times it drifts, and a status that fails over here but
  reads as healthy there is a quarantine nobody can explain.

  A `403` is the challenge response ADR-0038 decision 9 describes, `408` and
  `429` are the upstream telling us to back off, and a `5xx` is the upstream
  broken. Everything else, `404` included, is an answer.
  """
  @spec unhealthy_status?(Mint.Types.status()) :: boolean()
  def unhealthy_status?(status) when is_integer(status),
    do: status in @unhealthy_statuses or status >= 500
end

defmodule Raxol.Broker.MCP.Client do
  @moduledoc """
  The authenticated session to Robinhood's agent MCP server
  (`https://agent.robinhood.com/mcp/trading`), and the only way to reach it.

  It owns one unregistered `Raxol.MCP.Client`, so nothing else in the VM can
  call the upstream around `call/3`'s authorization. Headers are fixed when an
  MCP client connects, so a new bearer means a new inner client.

  ## Read-only, fail closed

  `call/3` admits only tools `Raxol.Broker.Tools.Catalog` classifies `:read`
  from the frozen capture; anything else is `{:error, {:tool_denied, name}}`
  before any request. On connect the live tool list is reconciled against
  the capture; `list_tools/1` returns the tools still `:read`, and
  `live_tools/1` the whole live list for `mix raxol.broker.capture_tools`.

  ## Tokens

  A refresh is scheduled `:refresh_skew` seconds (default 300) before
  `expires_at`; an expired credential is refreshed before use. A 401 starts
  one refresh that concurrent callers wait on; the rotated credential is
  persisted with `Raxol.Broker.CredentialStore` before it is used, and each
  waiting request is retried once. A 401 on that retry, on a fresh token,
  or a rejected refresh locks the session out: every call answers
  `{:error, :unauthorized}` until restart. A 403 is `{:error, {:http, 403}}`.
  A rotated credential that cannot be stored is kept in memory, unused,
  and the write is retried on the next request (`{:error, {:store_failed,
  reason}}` meanwhile).

  ## Throttling

  A `429`, `502`, `503` or `504` is retried after a jittered delay doubling
  from `:backoff`'s `:base_ms` (default 500) up to `:max_ms` (default 8000),
  at most `:retries` times (default 3), unless the delay would pass the
  caller's timeout or one more failure could open the circuit breaker
  (counting in-flight requests and scheduled retries). Sustained throttling
  can still open it (5 failures, 30 s), and calls then answer `{:error,
  :breaker_open}`. Order tools never take this path, so a throttled order
  is never resent.

  A transient connect failure (5xx or throttle at the handshake, a timeout,
  a transport or DNS failure) is retried the same way on a new inner client,
  at most `:retries` times in a run. A run that ends without connecting
  answers every call with its failure until a cooldown of `:base_ms *
  2^(retries + failed runs - 1)` (capped at `:max_ms`) ends; an expired
  credential still refreshes meanwhile, and a successful connect resets it.

  ## Options

  `:credential` (else read from the store), `:store`, `:url`, `:auth`
  (options for `Raxol.Agent.Auth.Robinhood.refresh/2`), `:mcp` (extra
  `Raxol.MCP.Client` spec keys), `:refresh_skew`, `:backoff` (`{:invalid_backoff, v}` if invalid),
  `:connect_timeout`, `:clock` (monotonic milliseconds, read for the
  cooldown) and `:name`. Neither `Inspect` nor `format_status/1` shows the
  credential, and no log line carries a token.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Broker.CredentialStore
  alias Raxol.Broker.MCP.Client.{Backoff, Refresh, State}
  alias Raxol.Broker.Redact
  alias Raxol.Broker.Tools.Catalog
  alias Raxol.MCP.CircuitBreaker
  alias Raxol.MCP.Client, as: Upstream
  alias Raxol.MCP.Client.Era
  alias Raxol.MCP.Client.Reservation

  @default_url "https://agent.robinhood.com/mcp/trading"
  @default_skew 300
  @default_connect_timeout 30_000
  @default_call_timeout 60_000
  # The endpoint speaks 2025-06-18 (initialize + Mcp-Session-Id) and refuses
  # `server/discover` with a plain-text 400. Pinned, so the probe is never
  # sent.
  @era :legacy

  @doc "Start the broker session. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The allowed (read-only) tools, from the list fetched at connect."
  @spec list_tools(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server, timeout \\ @default_call_timeout) do
    GenServer.call(server, {:list_tools, timeout}, timeout)
  end

  @doc """
  The whole tool list the server served at connect, unfiltered, or
  `{:error, :not_connected}`. Tool metadata only; nothing here can be called.
  """
  @spec live_tools(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, :not_connected}
  def live_tools(server, timeout \\ @default_call_timeout),
    do: GenServer.call(server, :live_tools, timeout)

  @doc """
  Call `tool_name` with `args`. A tool outside the read-only allowlist is
  `{:error, {:tool_denied, tool_name}}` and nothing is sent.
  """
  @spec call(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def call(server, tool_name, args, timeout \\ @default_call_timeout)
      when is_binary(tool_name) and is_map(args) do
    with :ok <- authorize_tool(tool_name) do
      GenServer.call(server, {:call, tool_name, args, timeout}, timeout)
    end
  end

  @doc """
  The authorization `call/3` applies: `:ok` for a tool the capture
  classifies `:read`, `{:error, {:tool_denied, name}}` for anything else.
  """
  # Checked again right before the upstream call.
  @spec authorize_tool(String.t()) :: :ok | {:error, {:tool_denied, String.t()}}
  def authorize_tool(name) when is_binary(name) do
    if Catalog.classify(name) == :read, do: :ok, else: {:error, {:tool_denied, name}}
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, credential} <- initial_credential(opts),
         {:ok, backoff} <- Backoff.config(Keyword.get(opts, :backoff, [])),
         {:ok, clock} <- clock(Keyword.get(opts, :clock)) do
      url = Keyword.get(opts, :url, @default_url)

      config = %{
        url: url,
        origin: {:origin, Era.origin(URI.parse(url))},
        store: Keyword.get(opts, :store, []),
        auth: Keyword.get(opts, :auth, []),
        mcp: Keyword.get(opts, :mcp, []),
        skew: Keyword.get(opts, :refresh_skew, @default_skew),
        connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout),
        backoff: backoff,
        clock: clock
      }

      state = %State{
        credential: credential,
        config: config,
        reservations: Reservation.new(:robinhood_reservations)
      }

      {:ok, state, {:continue, :start}}
    end
  end

  defp initial_credential(opts) do
    case Keyword.fetch(opts, :credential) do
      {:ok, %Credential{provider: :robinhood} = credential} ->
        {:ok, credential}

      :error ->
        case CredentialStore.fetch(Keyword.get(opts, :store, [])) do
          {:ok, credential} -> {:ok, credential}
          {:error, reason} -> {:stop, {:no_credential, reason}}
        end
    end
  end

  @impl GenServer
  def handle_continue(:start, state) do
    state = schedule_refresh(state)

    if Refresh.expired?(state.credential),
      do: {:noreply, start_refresh(state)},
      else: {:noreply, connect(state)}
  end

  @impl GenServer
  def handle_call(:live_tools, _from, %State{live: live} = state) when is_list(live),
    do: {:reply, {:ok, live}, state}

  def handle_call(:live_tools, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call({:list_tools, _timeout}, _from, %State{status: :unauthorized} = state),
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call({:list_tools, _timeout}, _from, %State{tools: tools} = state)
      when is_list(tools),
      do: {:reply, {:ok, tools}, state}

  def handle_call({:list_tools, timeout}, from, state),
    do: {:noreply, admit(state, from, :list_tools, Backoff.attempt(timeout))}

  def handle_call({:call, name, args, timeout}, from, state) do
    case authorize_tool(name) do
      :ok -> {:noreply, admit(state, from, {:call, name, args}, Backoff.attempt(timeout))}
      denied -> {:reply, denied, state}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, %State{task: {kind, ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finished(%{state | task: nil}, kind, result)
  end

  def handle_info({ref, result}, %State{requests: requests} = state)
      when is_reference(ref) and is_map_key(requests, ref) do
    Process.demonitor(ref, [:flush])
    {entry, requests} = Map.pop(requests, ref)
    {:noreply, completed(%{state | requests: requests}, entry, result)}
  end

  # A task that died never sent its result. Its exit reason is not logged:
  # it could be an exception carrying a request.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{task: {kind, ref}} = state) do
    failure = if kind == :connect, do: {:error, :upstream_down}, else: {:error, :refresh_crashed}
    finished(%{state | task: nil}, kind, failure)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{requests: requests} = state)
      when is_map_key(requests, ref) do
    {entry, requests} = Map.pop(requests, ref)
    {:noreply, completed(%{state | requests: requests}, entry, {:error, :upstream_down})}
  end

  def handle_info(
        {:refresh_due, generation},
        %State{generation: generation, status: :ready} = state
      ),
      do: {:noreply, start_refresh(%{state | timer: nil})}

  def handle_info({:refresh_due, _stale}, state), do: {:noreply, state}

  # The inner client is linked; this process traps exits so its death is a
  # message, not ours. A client that died unasked is replaced on next use.
  def handle_info({:EXIT, pid, _reason}, %State{inner: pid} = state) do
    drop_tables(state.tables)
    {:noreply, %{state | inner: nil, tables: nil, tools: nil}}
  end

  def handle_info({:backoff_retry, {pid, _tag} = from, request, attempt}, state) do
    state = %{state | scheduled_retries: max(state.scheduled_retries - 1, 0)}

    if caller_gone?(pid),
      do: {:noreply, state},
      else: {:noreply, admit(state, from, request, attempt)}
  end

  # The wait after a failed connect. A refresh or a connect started meanwhile
  # cleared `reconnect_ref`; a lock-out changed the status.
  def handle_info({:reconnect, ref}, %State{status: :connecting, reconnect_ref: ref} = state),
    do: {:noreply, connect(%{state | reconnect_ref: nil})}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    stop_inner(state)
    :ok
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, Redact.collapse(reason)}
      # Its tag only: an `{:EXIT, _, reason}` can carry the spec in a struct.
      {:message, message} -> {:message, Redact.shape(message)}
      {:state, state} -> {:state, State.scrub(state)}
      # `:sys` debug events carry the messages this process handled.
      {:log, _events} -> {:log, []}
      other -> other
    end)
  end

  defp finished(state, :connect, result), do: {:noreply, connected(state, result)}
  defp finished(state, :refresh, result), do: {:noreply, refreshed(state, result)}

  defp admit(%State{status: :unauthorized} = state, from, _request, _attempt) do
    GenServer.reply(from, {:error, :unauthorized})
    state
  end

  defp admit(%State{status: status} = state, from, request, attempt)
       when status in [:connecting, :refreshing] do
    enqueue(state, from, request, attempt)
  end

  defp admit(%State{unpersisted: %Credential{}} = state, from, request, attempt) do
    state |> start_refresh() |> enqueue(from, request, attempt)
  end

  defp admit(state, from, request, attempt) do
    if Refresh.expired?(state.credential),
      do: state |> start_refresh() |> enqueue(from, request, attempt),
      else: admit_live(state, from, request, attempt)
  end

  defp admit_live(%State{inner: nil} = state, from, request, attempt) do
    if cooling?(state),
      do: answer(state, from, {:error, state.cooldown.reason}),
      else: state |> connect() |> enqueue(from, request, attempt)
  end

  # A backoff retry checks the breaker again when its timer fires: calls made
  # since it was scheduled may have used the headroom it was scheduled with.
  # A retry after a refresh or a stale answer is not a throttle retry.
  defp admit_live(state, from, request, %{resend: true} = attempt) do
    if breaker_headroom?(state),
      do: send_request(state, from, request, attempt),
      else: answer(state, from, attempt.last)
  end

  defp admit_live(state, from, request, attempt), do: send_request(state, from, request, attempt)

  # After a connect run failed, calls are answered with its failure until the
  # cooldown ends, so a caller polling an origin that keeps failing cannot
  # start a new run per call.
  defp cooling?(%State{cooldown: %{until: until}} = state), do: state.config.clock.() < until
  defp cooling?(_state), do: false

  defp answer(state, from, reply) do
    GenServer.reply(from, reply)
    state
  end

  # Newest first; `flush_queue/1` and `fail_queue/2` restore arrival order.
  defp enqueue(state, from, request, attempt) do
    %{state | queue: [{from, request, attempt} | state.queue]}
  end

  defp send_request(state, from, request, attempt) do
    inner = state.inner
    task = Task.async(fn -> perform(inner, request) end)
    entry = {from, request, attempt, state.generation}
    %{state | requests: Map.put(state.requests, task.ref, entry)}
  end

  defp flush_queue(%State{queue: queue} = state) do
    queue
    |> Enum.reverse()
    |> Enum.reduce(%{state | queue: []}, fn {from, request, attempt}, acc ->
      admit(acc, from, request, attempt)
    end)
  end

  defp fail_queue(%State{queue: queue} = state, reply) do
    queue
    |> Enum.reverse()
    |> Enum.each(fn {from, _request, _attempt} -> GenServer.reply(from, reply) end)

    %{state | queue: []}
  end

  # Runs in a task: the only place the upstream is called.
  defp perform(inner, :list_tools), do: guarded(fn -> Upstream.list_tools(inner) end)

  defp perform(inner, {:call, name, args}) do
    with :ok <- authorize_tool(name) do
      guarded(fn -> Upstream.call_tool(inner, name, args) end)
    end
  end

  defp guarded(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :upstream_down}
  end

  defp completed(state, entry, result) do
    state |> disposition(entry, result) |> act(state, entry, result)
  end

  defp act(:unauthorized, state, {from, _request, _attempt, _generation}, _result) do
    GenServer.reply(from, {:error, :unauthorized})
    state
  end

  defp act(:retry_now, state, {from, request, attempt, _generation}, _result),
    do: admit(state, from, request, %{attempt | retried: true, resend: false})

  defp act(:retry_after_refresh, state, {from, request, attempt, _generation}, _result),
    do: enqueue(state, from, request, %{attempt | retried: true, resend: false})

  defp act(:reply, state, {from, request, attempt, generation}, result) do
    GenServer.reply(from, reply(request, attempt, result))
    mark_verified(state, generation, request, result)
  end

  defp act(:lock_out, state, {from, request, attempt, _generation}, _result),
    do: state |> enqueue(from, request, attempt) |> lock_out()

  defp act(:refresh, state, {from, request, attempt, _generation}, _result),
    do:
      state
      |> start_refresh()
      |> enqueue(from, request, %{attempt | retried: true, resend: false})

  defp act(:backoff, state, {from, request, attempt, _generation}, result) do
    attempt = %{attempt | throttled: attempt.throttled + 1, last: result, resend: true}

    Process.send_after(
      self(),
      {:backoff_retry, from, request, attempt},
      Backoff.jittered(state.config.backoff, attempt.throttled)
    )

    %{state | scheduled_retries: state.scheduled_retries + 1}
  end

  # A request sent with a token (or on an inner client) that has since been
  # replaced, or answered while that replacement is under way, is retried on
  # the new one rather than spending another refresh on a stale answer. A
  # 401 on a retry, or on a token fresh from a refresh, ends the session.
  defp disposition(state, {_from, _request, attempt, generation}, result) do
    cond do
      locked_out?(state, result) -> :unauthorized
      stale?(state, generation, result) -> :retry_now
      awaiting_refresh?(state, result) -> :retry_after_refresh
      retry_throttle?(state, attempt, result) -> :backoff
      not Backoff.unauthorized?(result) -> :reply
      attempt.retried or state.fresh -> :lock_out
      true -> :refresh
    end
  end

  defp locked_out?(state, result),
    do: state.status == :unauthorized and match?({:error, _}, result)

  defp stale?(state, generation, result), do: generation < state.generation and retryable?(result)
  defp awaiting_refresh?(state, result), do: state.status == :refreshing and retryable?(result)

  # What a burst of 401s leaves behind on the inner client it hit: the
  # 401s themselves, the per-client breaker they opened, or the client this
  # process stopped to replace. None of them says anything about the new token.
  defp retryable?({:error, :upstream_down}), do: true
  defp retryable?({:error, :breaker_open}), do: true
  defp retryable?(result), do: Backoff.unauthorized?(result)

  # A throttle status is retried while retries remain, the next delay ends
  # before the caller's deadline, and one more failure cannot open the breaker.
  defp retry_throttle?(state, attempt, result) do
    %{backoff: backoff} = state.config

    Backoff.throttled?(result) and attempt.throttled < backoff.retries and
      Backoff.within_deadline?(attempt, Backoff.max_delay(backoff, attempt.throttled)) and
      breaker_headroom?(state)
  end

  # Every request still in flight and every retry already scheduled may fail
  # too, so each counts as a failure the breaker has not seen yet.
  defp breaker_headroom?(%State{tables: %{breakers: breakers}, config: config} = state) do
    %{failures: failures} = CircuitBreaker.status(breakers, config.origin)
    pending = state.scheduled_retries + map_size(state.requests)
    failures + pending + 1 < CircuitBreaker.failure_threshold()
  end

  defp breaker_headroom?(_state), do: false

  # A throttled request whose retry found the breaker open answers with the
  # throttle status it was retrying, not with the breaker.
  defp reply(_request, %{last: {:error, _} = last}, {:error, :breaker_open}), do: last
  defp reply(request, _attempt, result), do: shape(request, result)

  defp caller_gone?(pid) when node(pid) == node(), do: not Process.alive?(pid)
  defp caller_gone?(_remote), do: false

  defp clock(nil), do: {:ok, fn -> System.monotonic_time(:millisecond) end}
  defp clock(clock) when is_function(clock, 0), do: {:ok, clock}
  defp clock(other), do: {:stop, {:invalid_clock, other}}

  defp shape(:list_tools, {:ok, tools}), do: {:ok, allowed(tools)}
  defp shape(_request, result), do: result

  defp mark_verified(%State{generation: generation} = state, generation, request, {:ok, value}) do
    state = %{state | fresh: false}
    if request == :list_tools, do: %{state | tools: allowed(value)}, else: state
  end

  defp mark_verified(state, _generation, _request, _result), do: state

  defp allowed(tools) do
    Enum.filter(tools, fn tool -> authorize_tool(tool_name(tool)) == :ok end)
  end

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_tool), do: ""

  defp connect(state) do
    state = stop_inner(state)
    tables = new_tables(state)

    spec =
      [
        name: :robinhood,
        url: state.config.url,
        headers: [{"authorization", Credential.bearer(state.credential)}],
        era: @era,
        tables: tables,
        fail_fast: true
      ] ++
        Keyword.drop(state.config.mcp, [:name, :url, :headers, :tables, :registry, :fail_fast])

    case Upstream.start_link(spec) do
      {:ok, pid} ->
        timeout = state.config.connect_timeout
        task = Task.async(fn -> await_tools(pid, timeout) end)

        %{
          state
          | inner: pid,
            tables: tables,
            tools: nil,
            status: :connecting,
            task: {:connect, task.ref},
            reconnect_ref: nil
        }

      # Collapsed for the callers too: a start error can carry the spec.
      {:error, reason} ->
        reason = Redact.collapse(reason)
        drop_tables(tables)
        log_failure("could not start the MCP client", reason)
        fail_queue(%{state | status: :ready}, {:error, reason})
    end
  end

  # A legacy session handshakes after the probe; `Upstream.await_ready/2` waits for
  # that. The inner client is fail-fast, so a failed connect or handshake
  # (a 401, a throttle) answers the wait at once instead of after the budget.
  # The whole attempt, both tool lists included, shares one `timeout` budget,
  # which is what the queued-caller guard in `reconnect_later/2` counts on; a
  # tool list that outlasts what is left of it is `{:error, :timeout}`.
  defp await_tools(pid, timeout) do
    deadline = Backoff.now_ms() + timeout

    guarded(fn -> pid |> bounded_list_tools(deadline) |> after_ready(pid, deadline) end)
  end

  defp after_ready({:error, {:not_ready, _status}}, pid, deadline) do
    with {:ok, _ready} <- Upstream.await_ready(pid, remaining(deadline)),
         do: bounded_list_tools(pid, deadline)
  end

  defp after_ready(result, _pid, _deadline), do: result

  defp bounded_list_tools(pid, deadline) do
    Upstream.list_tools(pid, timeout: remaining(deadline))
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  defp remaining(deadline), do: max(deadline - Backoff.now_ms(), 0)

  # A connect that failed transiently is retried while `:retries` remain in
  # this run; any other outcome ends the run.
  defp connected(state, result) do
    if reconnect?(state, result),
      do: reconnect_later(state, {:error, Backoff.transient(result)}),
      else: settled(%{state | reconnects: 0}, result)
  end

  defp settled(state, {:ok, tools}) do
    state = %{state | failed_runs: 0, cooldown: nil}
    session = Catalog.reconcile(tools)
    read = Enum.filter(tools, &(Catalog.class(session, tool_name(&1)) == :read))
    flush_queue(%{state | status: :ready, tools: read, live: tools, fresh: false})
  end

  defp settled(state, result) do
    if Backoff.unauthorized?(result),
      do: unauthorized(state),
      else: run_failed(state, result)
  end

  defp unauthorized(%State{fresh: true} = state), do: lock_out(state)
  defp unauthorized(state), do: start_refresh(state)

  # The failed inner client is stopped, which cancels its own retry, so the
  # next call starts a new bounded run instead of reaching it; but not before
  # a cooldown that keeps doubling across failed runs. The reason is
  # collapsed before it is kept; the documented shapes (`{:http, status}`,
  # `{:transport, kind}`, `{:timeout, phase}`) survive it.
  defp run_failed(state, result) do
    reason = Redact.collapse(Backoff.transient(result) || error_reason(result))
    log_failure("could not connect", reason)

    state
    |> stop_inner()
    |> cool_down(reason)
    |> Map.put(:status, :ready)
    |> fail_queue({:error, reason})
  end

  defp cool_down(state, reason) do
    failed_runs = state.failed_runs + 1
    retries = state.config.backoff.retries
    delay = Backoff.max_delay(state.config.backoff, retries + failed_runs - 1)
    until = state.config.clock.() + delay
    %{state | failed_runs: failed_runs, cooldown: %{until: until, reason: reason}}
  end

  defp reconnect?(state, result),
    do: Backoff.transient(result) != nil and state.reconnects < state.config.backoff.retries

  # A failed connect's backoff: the delay doubles with each failed connect in
  # the run. A queued caller whose deadline would pass before the next delay
  # and a whole connect budget is answered now instead of kept. The failed
  # inner client is stopped, which also cancels its own retry, so the
  # broker's `:retries` bounds the run.
  defp reconnect_later(state, reply) do
    backoff = state.config.backoff
    limit = Backoff.max_delay(backoff, state.reconnects) + state.config.connect_timeout

    {waiting, expiring} =
      Enum.split_with(state.queue, fn {_from, _request, attempt} ->
        Backoff.within_deadline?(attempt, limit)
      end)

    state = stop_inner(fail_queue(%{state | queue: expiring}, reply))
    reconnects = state.reconnects + 1
    ref = make_ref()
    Process.send_after(self(), {:reconnect, ref}, Backoff.jittered(backoff, reconnects))
    %{state | queue: waiting, reconnects: reconnects, reconnect_ref: ref}
  end

  defp error_reason({:error, reason}), do: reason
  defp error_reason(_other), do: :unexpected_response

  # Fresh era and breaker tables per inner client: a burst of 401s is an
  # authorization event, and must not leave a breaker open (or a cached era
  # that skips the probe) in front of the client started with the new token.
  defp new_tables(state) do
    %{
      eras: :ets.new(:robinhood_eras, [:set, :public]),
      breakers: CircuitBreaker.new(:robinhood_breakers),
      reservations: state.reservations
    }
  end

  defp stop_inner(%State{inner: nil} = state), do: state

  defp stop_inner(%State{inner: pid} = state) do
    try do
      Upstream.stop(pid)
    catch
      :exit, _reason -> :ok
    end

    drop_tables(state.tables)
    %{state | inner: nil, tables: nil}
  end

  defp drop_tables(nil), do: :ok

  defp drop_tables(tables) do
    :ets.delete(tables.eras)
    :ets.delete(tables.breakers)
    :ok
  end

  defp start_refresh(%State{status: :refreshing} = state), do: state

  defp start_refresh(state) do
    task = Task.async(Refresh.work(state))
    %{state | status: :refreshing, task: {:refresh, task.ref}, reconnect_ref: nil}
  end

  defp refreshed(state, {:ok, credential}) do
    Logger.info("[Broker.MCP] Robinhood token refreshed")

    %{
      state
      | credential: credential,
        unpersisted: nil,
        generation: state.generation + 1,
        fresh: true
    }
    |> schedule_refresh()
    |> connect()
  end

  defp refreshed(state, {:unpersisted, credential, reason}) do
    log_failure("refreshed but could not store the rotated credential", reason)

    %{state | unpersisted: credential, status: :ready}
    |> fail_queue({:error, {:store_failed, reason}})
  end

  defp refreshed(state, {:error, {:token_rejected, status, _code}}) when status in [400, 401] do
    lock_out(state)
  end

  defp refreshed(state, {:error, :no_refresh_token}), do: lock_out(state)

  defp refreshed(state, {:error, reason}) do
    log_failure("token refresh failed", reason)

    %{state | status: :ready}
    |> fail_queue({:error, {:refresh_failed, reason}})
  end

  defp lock_out(state) do
    Logger.warning("[Broker.MCP] Robinhood rejected the credential; sign in again")
    state = state |> stop_inner() |> cancel_timer()
    fail_queue(%{state | status: :unauthorized, tools: nil}, {:error, :unauthorized})
  end

  defp schedule_refresh(state) do
    state = cancel_timer(state)

    case Refresh.delay(state.credential, state.config.skew, DateTime.utc_now()) do
      nil ->
        state

      delay ->
        %{state | timer: Process.send_after(self(), {:refresh_due, state.generation}, delay)}
    end
  end

  defp cancel_timer(%State{timer: nil} = state), do: state

  defp cancel_timer(%State{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  # Collapsed first: a start_link error can carry the client spec, and so
  # its `{"authorization", "Bearer ..."}` header.
  defp log_failure(what, reason) do
    Logger.warning("[Broker.MCP] #{what}: #{inspect(Redact.collapse(reason), structs: false)}")
  end
end

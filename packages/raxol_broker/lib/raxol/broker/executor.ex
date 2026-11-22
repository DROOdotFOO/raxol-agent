defmodule Raxol.Broker.Executor do
  @moduledoc """
  The one path every order takes, each step journaled before the next runs:

      open_group   intent + context (policy and journal counters set here)
      verdict      :pre_review; DENY ends here
      review       the review tool's response; its warnings feed the context
      verdict      :post_review; DENY ends here, ASK parks the group
      [approval]   approve/3 or decline/3 on a parked group
      placing      Raxol.Broker.Executor.Place, with the ReviewReceipt
      order        :placed | :pending_approval | :failed | :unknown

  The executor sets the context's `policy`, `today_notional` (rolling 24 h
  back from `:clock`), `orders_last_minute` and `review_warnings`. Intent
  and context are rebuilt from plain data in the caller and again here.

  ## Guards

    * Decisions are serialized through this process. One executor per
      journal: `init/1` takes `Raxol.Broker.Journal.claim/1`, and the
      journal refuses group writes from any other process. The executor
      monitors the journal and stops with `{:journal_down, reason}` with it.
    * Only `Raxol.Broker.Executor.Place` names an order tool, and it needs a
      `Raxol.Broker.Executor.ReviewReceipt` for the same intent and group,
      verified under a key this process generates. No caller code runs
      here: `:journal` must be an atom or pid and `:clock` runs in a task.
    * Once the order call is made the result is `{:ok, map}`; if its record
      could not be written the map has `journaled: false` and
      `journal_error`, and the order may exist at the broker.
    * An intent id whose group reached `placing` without failing is
      `{:ok, :duplicate}`; every place also sends a `ref_id` derived from it.
      Pass `:id` to the `Raxol.Broker.Intent` constructor, or a re-run gets
      a fresh id and can place twice.
    * A review saying `customer_approval_required` makes a successful place
      `:pending_approval`; it keeps counting and its intent stays a duplicate.

  A post-review ASK parks the group and returns `{:ask, group_id, prompts}`.
  `approve/3` re-reads the counters, journals the approval and re-runs the
  policy (DENY ends the group); an approve refused before the approval is
  journaled leaves the group parked. `decline/3` and `close/3` end it.
  Parked groups live in this process; on start every open group is closed
  with `:executor_restarted`.

  The review runs in a task, so `parked/2` and `await_port/2` answer during
  it; other calls queue (a dead caller is dropped). The port
  (`Raxol.Broker.Executor.Port.MCP`) connects after `init/1`; until it is
  ready `run/3` and `approve/3` are `{:error, :port_not_ready}`. A dead port
  reconnects with backoff (doubling to 60 s), never restarting the executor.

  ## Options

  Required: `:policy` (`{:invalid_policy, r}`), `:session` (a sandboxed
  `Raxol.MCP.Client` spec, `:session_required`), `:account_number`.
  Optional: `:journal` (atom or pid, `{:invalid_journal, v}`), `:mode`
  (`:armed` is `:not_armed`), `:clock` (zero-arity, UTC `DateTime`, 5 s;
  a bad result is `{:error, {:context, r}}`), `:review_timeout`,
  `:place_timeout` (default 30 s) and `:reconnect_ms` (default 1 s), all ms
  in 1..4_294_000_000 (`{:invalid_timeout, key, v}`), `:name`. These stop
  the start; `:shutdown` (default `place_timeout + 5_000`) raises in
  `child_spec/1`. A second executor on a journal gets `{:journal_claimed, pid}`.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Secret
  alias Raxol.Broker.Executor.{Options, Parked, Place, Port, Review, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.{Intent, Journal, Plain, Policy}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Tools.Catalog
  import Raxol.Broker.Redact, only: [collapse: 1, shape: 1]

  @clock_timeout 5_000
  @max_backoff 60_000
  @max_timeout Options.max_timeout()

  @type placed :: %{
          required(:group_id) => String.t(),
          required(:status) => Place.status(),
          required(:response) => map(),
          required(:journaled) => boolean(),
          optional(:journal_error) => term()
        }

  @type result ::
          {:ok, placed()}
          | {:ok, :duplicate}
          | {:ask, String.t(), [{Policy.rule_id(), String.t()}]}
          | {:deny, String.t(), term()}
          | {:error, term()}

  @doc "Start the executor. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run `intent` through the pipeline. See the moduledoc.

  Both structs are rebuilt from plain data here (`Intent.normalize/1`,
  `Context.normalize/1`) and again inside the executor; anything else is
  `{:error, {:invalid_intent, reason}}` or `{:error, {:invalid_context,
  reason}}` and nothing is sent to the executor.
  """
  @spec run(GenServer.server(), Intent.t(), Context.t()) :: result()
  def run(server, %Intent{} = intent, %Context{} = context) do
    with {:ok, intent, context} <- Policy.normalize(intent, context),
         do: GenServer.call(server, {:run, intent, context}, :infinity)
  end

  @doc "Approve a parked ASK; `by` names who approved (non-empty string)."
  @spec approve(GenServer.server(), String.t(), String.t()) :: result()
  def approve(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:approve, token, by}, :infinity)

  @doc "Decline a parked ASK; the group ends as DENY. `by` is a non-empty string."
  @spec decline(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def decline(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:decline, token, by}, :infinity)

  @doc "Abandon a parked ASK with `{:close, reason}`; `reason` is a non-nil atom."
  @spec close(GenServer.server(), String.t(), atom()) :: :ok | {:error, term()}
  def close(server, token, reason)
      when is_binary(token) and is_atom(reason) and not is_nil(reason),
      do: GenServer.call(server, {:close, token, reason}, :infinity)

  @doc "Parked ASKs: `[%{group_id, intent, prompts}]`, oldest first."
  @spec parked(GenServer.server(), timeout()) :: [map()]
  def parked(server, timeout \\ :infinity), do: GenServer.call(server, :parked, timeout)

  @doc """
  Wait until the port session is ready: `:ok`, or `{:error, :port_not_ready}`
  once `timeout` milliseconds pass first. Answered even while a review is in
  flight. A timeout above 4_294_000_000 ms is `{:error, {:invalid_timeout,
  :await_port, timeout}}`.
  """
  @spec await_port(GenServer.server(), non_neg_integer()) ::
          :ok | {:error, :port_not_ready | {:invalid_timeout, :await_port, term()}}
  def await_port(server, timeout \\ Options.default_timeout())
      when is_integer(timeout) and timeout >= 0,
      do: GenServer.call(server, {:await_port, timeout}, :infinity)

  @doc """
  A child spec whose `:shutdown` covers one place call (`place_timeout +
  5_000`, or the `:shutdown` option), so a supervisor stopping the executor
  mid-place waits for the order response. A `:shutdown` that is not a
  positive integer raises `ArgumentError`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Options.shutdown(opts)
    }
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- Options.check(opts),
         {:ok, client_spec} <- prepare_port(config),
         {:ok, journal_ref} <- monitor_journal(config.journal),
         :ok <- safe(fn -> Journal.claim(config.journal) end) do
      state = base_state(config, client_spec, journal_ref)
      close_orphans(state)
      {:ok, state, {:continue, :connect}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Pure: refuses a live spec before anything connects.
  defp prepare_port(config),
    do:
      PortMCP.prepare(config.session,
        mode: :dry_run,
        call_timeout: max(config.review_timeout, config.place_timeout),
        reconnect_ms: config.reconnect_ms
      )

  # The claim lives in the journal's memory, so a journal restart drops it.
  # The executor stops with the journal; its supervisor restarts it, and the
  # new one claims again and closes the groups this one left open.
  defp monitor_journal(journal) when is_pid(journal), do: {:ok, Process.monitor(journal)}

  defp monitor_journal(journal) do
    case Process.whereis(journal) do
      pid when is_pid(pid) -> {:ok, Process.monitor(pid)}
      nil -> {:error, :journal_not_running}
    end
  end

  defp base_state(config, client_spec, journal_ref) do
    %{
      journal: config.journal,
      journal_ref: journal_ref,
      clock: config.clock,
      account: config.account,
      policy: config.policy,
      review_timeout: config.review_timeout,
      place_timeout: config.place_timeout,
      key: :crypto.strong_rand_bytes(32),
      client_spec: client_spec,
      port: nil,
      port_status: :connecting,
      connect: nil,
      catalog: %{},
      reconnect_ms: config.reconnect_ms,
      backoff: config.reconnect_ms,
      port_waiters: %{},
      parked: Parked.new(),
      busy: nil,
      queue: :queue.new()
    }
  end

  # A group the journal still has open was parked or mid-flight in an
  # executor that is gone; nothing may resume it.
  defp close_orphans(state) do
    case safe(fn -> Journal.open_groups(state.journal) end) do
      {:ok, ids} ->
        Enum.each(ids, &close_group(state, &1, :executor_restarted))

      {:error, reason} ->
        Logger.warning(
          "[Broker.Executor] could not list open groups: #{inspect(reason, structs: false)}"
        )
    end
  end

  @impl GenServer
  def handle_call(:parked, _from, state) do
    {:reply, Parked.list(state.parked), state}
  end

  def handle_call({:await_port, _timeout}, _from, %{port_status: :ready} = state),
    do: {:reply, :ok, state}

  def handle_call({:await_port, timeout}, from, state)
      when is_integer(timeout) and timeout >= 0 and timeout <= @max_timeout do
    timer = Process.send_after(self(), {:await_port_timeout, from}, timeout)
    {:noreply, %{state | port_waiters: Map.put(state.port_waiters, from, timer)}}
  end

  def handle_call({:await_port, timeout}, _from, state),
    do: {:reply, {:error, {:invalid_timeout, :await_port, timeout}}, state}

  # Nothing jumps the queue: a request that arrives while earlier ones wait
  # for their `:drain` turn is queued behind them.
  def handle_call(request, {pid, _tag} = from, state) do
    if state.busy == nil and :queue.is_empty(state.queue) do
      case dispatch(request, from, state) do
        {:reply, reply, state} -> {:reply, reply, state}
        {:await, state} -> {:noreply, state}
      end
    else
      entry = {request, from, Process.monitor(pid)}
      {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_info({ref, result}, %{busy: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    review_done(state, result)
  end

  def handle_info({ref, result}, %{connect: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, connected(%{state | connect: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %{ref: ref}} = state),
    do: review_done(state, {:error, {:review_crashed, collapse(reason)}})

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connect: %Task{ref: ref}} = state),
    do: {:noreply, connected(%{state | connect: nil}, {:error, {:connect_crashed, reason}})}

  # Queued callers get an exit from their call; the linked review task dies
  # with this process; the groups left open are closed by the next executor.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{journal_ref: ref} = state) do
    Logger.warning("[Broker.Executor] journal went down: #{inspect(reason, structs: false)}")
    {:stop, {:journal_down, reason}, state}
  end

  # A queued caller died: drop its request.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {gone, queue} = :queue.to_list(state.queue) |> Enum.split_with(&(elem(&1, 2) == ref))
    Enum.each(gone, fn {request, _from, _ref} -> dropped(request) end)
    {:noreply, %{state | queue: :queue.from_list(queue)}}
  end

  # The connect task is shut down for its side effect only; the state is
  # updated whatever `Task.shutdown/2` returns.
  def handle_info({:EXIT, pid, reason}, %{port: {PortMCP, %PortMCP{pid: pid}}} = state) do
    if state.connect, do: Task.shutdown(state.connect, :brutal_kill)
    {:noreply, port_failed(%{state | port: nil, connect: nil}, {:port_exited, reason})}
  end

  # Review, clock and connect tasks are linked; their exits are handled
  # through their monitors. A port this process stopped exits here too.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{port: nil} = state), do: {:noreply, connect(state)}

  # A `:drain` left over from an earlier turn can arrive while a review is
  # in flight; `review_done/2` sends a fresh one when it finishes.
  def handle_info(:drain, %{busy: nil} = state), do: {:noreply, drain(state)}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({:await_port_timeout, from}, state) do
    case Map.pop(state.port_waiters, from) do
      {nil, _waiters} ->
        {:noreply, state}

      {_timer, waiters} ->
        GenServer.reply(from, {:error, :port_not_ready})
        {:noreply, %{state | port_waiters: waiters}}
    end
  end

  # Only the shape is logged: the message is any term, and inspecting a
  # struct would run its Inspect implementation here.
  def handle_info(message, state) do
    Logger.debug("[Broker.Executor] unexpected message: #{shape(message)}")
    {:noreply, state}
  end

  # Nothing is cast to the executor. The default clause would crash it, and
  # the crash report would inspect the message in this process.
  @impl GenServer
  def handle_cast(message, state) do
    Logger.debug("[Broker.Executor] unexpected cast: #{shape(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, state), do: Port.stop(state.port)

  # The client connects on its own (retrying a failed connect with backoff
  # from `:reconnect_ms`); a task waits for it, so this process keeps
  # answering meanwhile.
  defp connect(state) do
    case PortMCP.start_client(state.client_spec) do
      {:ok, port} ->
        task = Task.async(fn -> await_catalog(port) end)
        %{state | port: port, port_status: :connecting, connect: task}

      {:error, reason} ->
        port_failed(state, {:connect_failed, reason})
    end
  end

  # The session's tool classes: the live list reconciled against the frozen
  # capture (`Raxol.Broker.Tools.Catalog`). A port whose list cannot be read
  # never becomes ready, so no tool is ever called unclassified.
  #
  # An exit from the client is caught here and collapsed, so the task never
  # crashes with (and logs) a reason that can carry the client spec.
  defp await_catalog(port) do
    with :ok <- PortMCP.await_ready(port),
         {:ok, tools} <- PortMCP.list_tools(port) do
      {:ok, Catalog.reconcile(tools)}
    end
  catch
    :exit, reason -> {:error, collapse(reason)}
  end

  defp connected(state, {:ok, catalog}) do
    Enum.each(state.port_waiters, fn {from, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    %{
      state
      | port_status: :ready,
        catalog: catalog,
        backoff: state.reconnect_ms,
        port_waiters: %{}
    }
  end

  defp connected(%{port: port} = state, {:error, reason}) do
    if port, do: Port.stop(port)
    port_failed(%{state | port: nil}, {:connect_failed, reason})
  end

  # The reason is collapsed before it is logged or kept: an exit from the
  # inner MCP client can carry a stacktrace whose arguments are the client
  # spec, bearer header included.
  defp port_failed(state, reason) do
    reason = collapse(reason)

    Logger.warning(
      "[Broker.Executor] port not ready (#{inspect(reason, structs: false)}); " <>
        "reconnecting in #{state.backoff} ms"
    )

    Process.send_after(self(), :reconnect, state.backoff)

    %{
      state
      | port_status: {:down, reason},
        backoff: min(state.backoff * 2, @max_backoff)
    }
  end

  # The receipt key and the session spec (bearer header, stdio env) never
  # reach a crash report or `:sys.get_status`; neither do the failure terms
  # OTP adds next to the state.
  @impl GenServer
  def format_status(status) do
    status
    |> Raxol.Agent.Secret.redact_status([:key, :client_spec, :account])
    |> Map.new(fn
      {:reason, reason} -> {:reason, collapse(reason)}
      {:message, message} -> {:message, shape(message)}
      other -> other
    end)
  end

  defp dispatch({:run, intent, context}, from, state) do
    case Policy.normalize(intent, context) do
      {:ok, intent, context} -> awaiting(run_intent(state, intent, context), from)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch({:approve, token, by}, _from, state),
    do: approve_parked(state, token, by)

  defp dispatch({:decline, token, by}, _from, state),
    do: finish_parked(state, token, {:approval, :declined, by})

  defp dispatch({:close, token, reason}, _from, state),
    do: finish_parked(state, token, {:close, reason})

  defp dispatch(_request, _from, state), do: {:reply, {:error, :unknown_request}, state}

  defp awaiting({:await, pending, state}, from),
    do: {:await, %{state | busy: Map.put(pending, :from, from)}}

  defp awaiting(done, _from), do: done

  defp review_done(%{busy: pending} = state, result) do
    {:reply, reply, state} = reviewed(%{state | busy: nil}, pending, result)
    GenServer.reply(pending.from, reply)
    {:noreply, drain_later(state)}
  end

  defp drain(%{busy: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, entry}, queue} ->
        drain_entry(%{state | queue: queue}, entry)
    end
  end

  # A caller that died while queued is never dispatched: its order would be
  # placed with nobody to receive the result. Its monitor tells: a DOWN
  # already delivered (but not yet handled) makes the demonitor report
  # false. `Process.alive?/1` is only asked about a local pid.
  #
  # At most one request is dispatched per callback, so one callback never
  # runs more than one place call: the rest wait for a `:drain` message,
  # and the shutdown bound covers the one in progress.
  defp drain_entry(state, {request, {pid, _tag} = from, ref}) do
    if Process.demonitor(ref, [:flush, :info]) and (node(pid) != node() or Process.alive?(pid)) do
      case dispatch(request, from, state) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          drain_later(state)

        {:await, state} ->
          state
      end
    else
      dropped(request)
      drain(state)
    end
  end

  defp drain_later(state) do
    unless :queue.is_empty(state.queue), do: send(self(), :drain)
    state
  end

  defp dropped(request),
    do: Logger.info("[Broker.Executor] dropped a queued #{request_kind(request)}: caller is gone")

  defp request_kind(request) when is_tuple(request) and is_atom(elem(request, 0)),
    do: elem(request, 0)

  defp request_kind(_request), do: :request

  defp run_intent(state, intent, context) do
    with :ok <- port_up(state),
         :ok <- Parked.check_intent(state.parked, intent),
         {:ok, nil} <- placed_before(state, intent),
         {:ok, _tool} <- Review.tool(intent),
         {:ok, context} <- fill(state, %{context | review_warnings: []}),
         {:ok, group_id} <- open(state, intent, context) do
      pre_review(state, intent, context, group_id)
    else
      {:ok, group_id} when is_binary(group_id) -> {:reply, {:ok, :duplicate}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp port_up(%{port_status: :ready}), do: :ok
  defp port_up(_state), do: {:error, :port_not_ready}

  defp placed_before(state, intent),
    do: safe(fn -> Journal.placing_for_intent(intent.id, state.journal) end)

  defp open(state, intent, context),
    do: safe(fn -> Journal.open_group(intent, context, state.journal, mode: :dry_run) end)

  defp pre_review(state, intent, context, group_id) do
    verdict = Policy.evaluate(intent, context)

    case {append(state, group_id, {:verdict, :pre_review, verdict}), verdict} do
      {{:error, reason}, _verdict} -> {:reply, {:error, reason}, state}
      {:ok, {:deny, reason}} -> {:reply, {:deny, group_id, reason}, state}
      {:ok, _allow_or_ask} -> review(state, intent, context, group_id)
    end
  end

  defp review(state, intent, context, group_id) do
    %{port: port, catalog: catalog, account: account, review_timeout: timeout} = state
    task = Task.async(fn -> Review.run(port, catalog, intent, account, timeout) end)
    pending = %{ref: task.ref, pid: task.pid, intent: intent, context: context}
    {:await, Map.put(pending, :group_id, group_id), state}
  end

  defp reviewed(state, %{group_id: group_id}, {:error, reason}) do
    _ = close_group(state, group_id, :review_failed)
    {:reply, {:error, reason}, state}
  end

  defp reviewed(state, pending, {:ok, response, warnings}) do
    pending =
      pending
      |> Map.put(:context, %{pending.context | review_warnings: warnings})
      |> Map.put(:customer_approval_required, Review.customer_approval_required?(response))

    case append(state, pending.group_id, {:review, response}) do
      :ok -> post_review(state, pending)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp post_review(state, %{intent: intent, group_id: group_id} = pending) do
    receipt = ReviewReceipt.issue(state.key, intent, group_id)
    verdict = Policy.evaluate(intent, pending.context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        {:reply, {:error, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, {:ask, prompts}} ->
        park(state, pending, receipt, prompts)

      {:ok, {:allow, _intent}} ->
        place(state, intent, group_id, receipt, pending.customer_approval_required)
    end
  end

  defp park(state, %{group_id: group_id} = pending, receipt, prompts) do
    parked = Parked.put(state.parked, group_id, pending, receipt, prompts)
    {:reply, {:ask, group_id, prompts}, %{state | parked: parked}}
  end

  # Everything before the approval is journaled leaves the group parked.
  defp approve_parked(state, token, by) do
    with :ok <- port_up(state),
         {:ok, group} <- Parked.fetch(state.parked, token),
         {:ok, context} <- fill(state, group.context) do
      approved(state, token, group, by, context)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp approved(state, group_id, group, by, context) do
    unparked = %{state | parked: Parked.delete(state.parked, group_id)}

    case append(state, group_id, {:approval, :approved, by}) do
      :ok ->
        recheck(unparked, group_id, group, context)

      {:error, {:invalid_entry, _} = reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        _ = close_group(unparked, group_id, :approval_failed)
        {:reply, {:error, reason}, unparked}
    end
  end

  defp recheck(state, group_id, group, context) do
    verdict = Policy.evaluate(group.intent, context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        _ = close_group(state, group_id, :approval_failed)
        {:reply, {:error, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, _ask_answered_or_allow} ->
        place(state, group.intent, group_id, group.receipt, group.customer_approval_required)
    end
  end

  # Dropped from the parked map whatever the journal says: without its
  # receipt the group can never reach `placing`.
  defp finish_parked(state, token, entry) do
    case Parked.pop(state.parked, token) do
      {:ok, parked} -> {:reply, append(state, token, entry), %{state | parked: parked}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The port can go down between review and here (its EXIT handled before
  # the review result): close the group without `placing`, send nothing.
  defp place(%{port_status: status, port: port} = state, _intent, group_id, _receipt, _approval)
       when status != :ready or is_nil(port) do
    _ = close_group(state, group_id, :port_not_ready)
    {:reply, {:error, :port_not_ready}, state}
  end

  defp place(state, intent, group_id, receipt, customer_approval_required) do
    env = %{
      port: state.port,
      catalog: state.catalog,
      journal: state.journal,
      account: state.account,
      key: Secret.new(state.key),
      timeout: state.place_timeout,
      customer_approval_required: customer_approval_required
    }

    reply =
      case Place.run(receipt, intent, group_id, env) do
        {:ok, status, response} ->
          {:ok, %{group_id: group_id, status: status, response: response, journaled: true}}

        {:error, {:order_unjournaled, status, response, reason}} ->
          {:ok,
           %{
             group_id: group_id,
             status: status,
             response: response,
             journaled: false,
             journal_error: reason
           }}

        # `placing` was refused, the receipt failed, or the intent has no
        # order tool: nothing was sent.
        {:error, reason} ->
          _ = close_group(state, group_id, :placing_refused)
          {:error, reason}
      end

    {:reply, reply, state}
  end

  # The window is a rolling 24 hours back from this executor's clock; no
  # caller input moves it.
  defp fill(state, %Context{} = context) do
    with {:ok, now} <- now(state.clock),
         day_start = DateTime.add(now, -24, :hour),
         {:ok, notional} <- safe(fn -> Journal.today_notional(day_start, state.journal) end),
         {:ok, count} <- safe(fn -> Journal.orders_last_minute(now, state.journal) end) do
      {:ok,
       %{context | policy: state.policy, today_notional: notional, orders_last_minute: count}}
    else
      {:error, reason} -> {:error, {:context, reason}}
    end
  end

  # The clock is caller code, so it runs in a task: never in this process,
  # where it would hold the executor's identity and journal claim. Its result
  # is rebuilt by pattern matching before any Calendar function sees it.
  defp now(clock) do
    task = Task.async(clock)

    case Task.yield(task, @clock_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, %DateTime{} = now} -> utc(Plain.normalize(now))
      {:ok, other} -> {:error, {:invalid_clock, other}}
      {:exit, reason} -> {:error, {:clock_crashed, reason}}
      nil -> {:error, :clock_timeout}
    end
  end

  # Plain rebuilds an ISO DateTime with integer fields; the offsets and the
  # field ranges are checked here so no Calendar.ISO function can raise.
  defp utc(
         {:ok,
          %DateTime{
            time_zone: "Etc/UTC",
            utc_offset: 0,
            std_offset: 0,
            microsecond: {micro, precision}
          } = now}
       )
       when precision in 0..6 do
    if Calendar.ISO.valid_date?(now.year, now.month, now.day) and
         Calendar.ISO.valid_time?(now.hour, now.minute, now.second, {micro, precision}),
       do: {:ok, now},
       else: {:error, {:invalid_clock, now}}
  end

  defp utc({:ok, other}), do: {:error, {:invalid_clock, other}}
  defp utc({:error, reason}), do: {:error, {:invalid_clock, reason}}

  defp close_group(state, group_id, reason) do
    with {:error, error} <- append(state, group_id, {:close, reason}) do
      Logger.warning(
        "[Broker.Executor] could not close group #{group_id} (#{reason}): " <>
          inspect(error, structs: false)
      )

      {:error, error}
    end
  end

  defp append(state, group_id, entry),
    do: safe(fn -> Journal.append_to_group(group_id, entry, state.journal) end)

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end
end

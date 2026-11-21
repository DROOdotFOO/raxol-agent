defmodule Raxol.AgentClientProtocol.Session do
  @moduledoc """
  One GenServer per `{connection, session_id}`: the ACP turn state machine.

  The turn is `:idle | {:prompting, Turn} | {:cancelling, Turn}`. A prompt runs
  in a supervised root task (the injected `:turn_runner`), which may spawn more
  tasks into the turn group with `spawn_task/2`. The prompt reply is sent once
  the group has drained, through the Connection's delegated-reply mechanism, so
  every `session/update` precedes it on the same FIFO lane.

    * Cancel and prompt commute by wire order: a `session/cancel` latches its
      `rx_seq`, and a prompt ordered before it resolves `cancelled` immediately.
    * Cancelling sends `:acp_cancel` to the root task and arms a backstop that
      kills the group after `:cancel_backstop_ms` (default 30s).
    * Permission asks fail closed: anything but a decoded `:selected` outcome
      denies, and cancelling a turn denies its open asks.
    * Registration happens in `start_link/1`, before `init/1`, so the session
      is reachable before any response announces it.

  Seams: `:conn_mod` (the Connection module), `:emitter` (`Session.Emitter`),
  `:steer_adapter` (`Session.SteerAdapter`). With a finite `:idle_timeout` in
  `:config`, an idle session stops itself and its emitter's Writer; the
  journal is kept, so a later `session/load` replays it.
  """

  use GenServer
  require Logger

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse
  alias Raxol.AgentClientProtocol.Session.{SteerAdapter, Turn}
  alias Raxol.AgentClientProtocol.Telemetry

  @default_permission_timeout 600_000
  @default_cancel_backstop_ms 30_000

  # Idle reaping is off by default. Reaping never truncates the append-only
  # journal; retention is the journal store owner's concern.
  @default_idle_timeout :infinity
  @default_conn_mod Raxol.AgentClientProtocol.Connection

  @default_emitter Raxol.AgentClientProtocol.Session.Emitter.Direct

  # Refuses every steer with `{:error, :no_steer_channel}`.
  @default_steer_adapter Raxol.AgentClientProtocol.Session.SteerAdapter.Unsupported

  @registry Raxol.AgentClientProtocol.SessionRegistry

  @type t :: %__MODULE__{
          session_id: String.t(),
          conn: pid(),
          conn_mod: module(),
          task_sup: pid() | atom(),
          turn_runner: (pid(), struct() -> {:stop, atom()} | PromptResponse.t()),
          mode_state: SessionModeState.t() | nil,
          turn: :idle | {:prompting, Turn.t()} | {:cancelling, Turn.t()},
          last_cancel_seq: non_neg_integer(),
          emitter: module(),
          journal: {module(), term()} | nil,
          turn_seq: non_neg_integer(),
          idle_timer: reference() | nil,
          idle_epoch: non_neg_integer(),
          steer_adapter: module(),
          steer_state: term(),
          config: %{
            permission_timeout: timeout(),
            cancel_backstop_ms: pos_integer(),
            idle_timeout: timeout()
          }
        }

  defstruct session_id: nil,
            conn: nil,
            conn_mod: @default_conn_mod,
            task_sup: nil,
            turn_runner: nil,
            mode_state: nil,
            turn: :idle,
            last_cancel_seq: 0,
            emitter: @default_emitter,
            journal: nil,
            turn_seq: 0,
            idle_timer: nil,
            idle_epoch: 0,
            steer_adapter: @default_steer_adapter,
            steer_state: nil,
            config: %{}

  @doc "The session `Registry`. Keys are `{conn_pid, session_id}`."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The `:via` name of the Session for `{conn, session_id}`."
  @spec via(pid(), String.t()) :: {:via, module(), {atom(), {pid(), String.t()}}}
  def via(conn, session_id) when is_pid(conn) and is_binary(session_id) do
    {:via, Registry, {@registry, {conn, session_id}}}
  end

  @doc """
  Starts a Session, registered under `via/2` before `init/1` runs. A live
  duplicate returns `{:error, {:already_started, pid}}`.

  Options: `:session_id`, `:conn` and `:task_sup` (required); `:turn_runner`
  (required to prompt: `(session_pid, prompt_request) -> {:stop, reason} |
  %PromptResponse{} | {:error, %Error{}}`); `:mode_state`; `:conn_mod` (default
  `#{inspect(@default_conn_mod)}`); `:emitter`; `:journal`; `:steer_adapter`;
  `:steer_state`; `:config` (`:permission_timeout`, `:cancel_backstop_ms`,
  `:idle_timeout`); `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    conn = Keyword.fetch!(opts, :conn)
    name = Keyword.get(opts, :name, via(conn, session_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Begins a prompt turn; called from the `session/prompt` handler task. Adopts the
  reply obligation and returns `:ok` (the handler then returns `:deferred`). A
  session with a live turn returns `{:error, %Error{}}` without adopting, and the
  handler replies with it.
  """
  @spec begin_prompt(GenServer.server(), struct(), reference(), non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def begin_prompt(session, req, reply_ref, rx_seq)
      when is_reference(reply_ref) and is_integer(rx_seq) do
    GenServer.call(session, {:begin_prompt, req, reply_ref, rx_seq})
  end

  @doc "Sets the active mode; an unknown mode or `nil` mode state is `-32602`."
  @spec set_mode(GenServer.server(), String.t()) ::
          {:ok, SetSessionModeResponse.t()} | {:error, Error.t()}
  def set_mode(session, mode_id) when is_binary(mode_id) do
    GenServer.call(session, {:set_mode, mode_id})
  end

  @doc """
  Emits a `session/update` for the live turn. Empty text chunks return
  `{:error, :empty_chunk}`; with no live turn, `{:error, :turn_over}`.
  """
  @spec post_update(GenServer.server(), struct()) :: :ok | {:error, :turn_over | :empty_chunk}
  def post_update(session, notification) do
    GenServer.call(session, {:post_update, notification})
  end

  @doc """
  Asks the client for permission and blocks until it answers. Only a decoded
  selected outcome returns `{:ok, {:selected, outcome}}`; timeout, error,
  disconnect or cancel all return `{:ok, :cancelled}`.
  """
  @spec request_permission(GenServer.server(), struct()) ::
          {:ok, {:selected, struct()}} | {:ok, :cancelled}
  def request_permission(session, req) do
    GenServer.call(session, {:request_permission, req}, :infinity)
  end

  @doc """
  Spawns a task into the live turn's group; the prompt reply waits for it.
  Returns `{:error, :turn_over}` when no turn is prompting.
  """
  @spec spawn_task(GenServer.server(), (-> any())) :: {:ok, reference()} | {:error, :turn_over}
  def spawn_task(session, fun) when is_function(fun, 0) do
    GenServer.call(session, {:spawn_task, fun})
  end

  @doc """
  Redirects the running turn with new input, via the injected `SteerAdapter`'s
  compare-and-swap on `expected_turn_id`. On `{:ok, {:accepted, ref}}` the text
  is sent to the root task as `{:acp_steer, text}` and the emitter records it;
  see `t:SteerAdapter.result/0` for the other outcomes.
  """
  @spec steer(GenServer.server(), SteerAdapter.request()) :: SteerAdapter.result()
  def steer(session, request) when is_map(request) do
    GenServer.call(session, {:steer, request})
  end

  # -- Callbacks --------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      conn: Keyword.fetch!(opts, :conn),
      conn_mod: Keyword.get(opts, :conn_mod, @default_conn_mod),
      task_sup: Keyword.get(opts, :task_sup),
      turn_runner: Keyword.get(opts, :turn_runner),
      mode_state: Keyword.get(opts, :mode_state),
      emitter: Keyword.get(opts, :emitter, @default_emitter),
      journal: Keyword.get(opts, :journal),
      steer_adapter: Keyword.get(opts, :steer_adapter, @default_steer_adapter),
      steer_state: Keyword.get(opts, :steer_state),
      config: normalize_config(Keyword.get(opts, :config, %{}))
    }

    {:ok, arm_idle(state)}
  end

  @impl true
  def handle_call({:begin_prompt, req, reply_ref, rx_seq}, _from, %{turn: :idle} = state) do
    # Adopt first: the call returns before the handler can return :deferred.
    _ = state.conn_mod.delegate_reply(state.conn, reply_ref, self())

    if rx_seq < state.last_cancel_seq do
      _ = state.conn_mod.reply(state.conn, reply_ref, {:ok, PromptResponse.new(:cancelled)})
      {:reply, :ok, arm_idle(state)}
    else
      {:reply, :ok, start_turn(state, req, reply_ref, rx_seq)}
    end
  end

  def handle_call({:begin_prompt, _req, _reply_ref, _rx_seq}, _from, state),
    do: {:reply, {:error, busy()}, state}

  def handle_call({:set_mode, mode_id}, _from, state) do
    if valid_mode?(state.mode_state, mode_id) do
      mode_state = %{state.mode_state | current_mode_id: mode_id}
      {:reply, {:ok, SetSessionModeResponse.new()}, %{state | mode_state: mode_state}}
    else
      {:reply, {:error, Error.new(Error.invalid_params_code(), "unknown or unavailable mode")},
       state}
    end
  end

  def handle_call({:post_update, notification}, _from, %{turn: {ts, t}} = state) do
    if Turn.empty_chunk?(notification) do
      Logger.debug("ACP: rejected empty session/update chunk for #{inspect(state.session_id)}")
      Telemetry.execute([:raxol, :acp, :empty_chunk_rejected], %{session_id: state.session_id})
      {:reply, {:error, :empty_chunk}, state}
    else
      _ = state.emitter.emit(state, notification)
      {:reply, :ok, %{state | turn: {ts, %{t | updates_emitted?: true}}}}
    end
  end

  def handle_call({:post_update, _notification}, _from, state),
    do: {:reply, {:error, :turn_over}, state}

  # The task stays parked in the call; the answer arrives as `:acp_result`. The
  # Connection owns the timeout.
  def handle_call({:request_permission, req}, from, %{turn: {:prompting, t}} = state) do
    tag = make_ref()
    timeout = state.config.permission_timeout

    case state.conn_mod.async_request(
           state.conn,
           "session/request_permission",
           req,
           self(),
           tag,
           timeout
         ) do
      :ok ->
        t = %{t | pending_perms: Map.put(t.pending_perms, tag, %{from: from})}
        {:noreply, %{state | turn: {:prompting, t}}}

      {:error, _reason} ->
        {:reply, {:ok, :cancelled}, state}
    end
  end

  def handle_call({:request_permission, _req}, _from, state),
    do: {:reply, {:ok, :cancelled}, state}

  def handle_call({:spawn_task, fun}, _from, %{turn: {:prompting, t}} = state) do
    task = Task.Supervisor.async_nolink(state.task_sup, fun)
    t = %{t | monitors: Map.put(t.monitors, task.ref, task.pid)}
    {:reply, {:ok, task.ref}, %{state | turn: {:prompting, t}}}
  end

  def handle_call({:spawn_task, _fun}, _from, state), do: {:reply, {:error, :turn_over}, state}

  # The CAS runs in this mailbox, so steer state has a single writer. Only an
  # accept has side effects.
  def handle_call({:steer, request}, _from, state) do
    {result, steer_state} = state.steer_adapter.resolve(state.steer_state, request)
    state = %{state | steer_state: steer_state}

    case result do
      {:ok, {:accepted, ref}} -> {:reply, result, steer_accepted(state, ref, request)}
      _rejected_or_duplicate -> {:reply, result, state}
    end
  end

  @impl true
  def handle_cast({:acp_session_cancel, seq}, %{turn: :idle} = state) do
    Logger.debug("acp session cancel of idle session #{inspect(state.session_id)} (latch #{seq})")
    {:noreply, %{state | last_cancel_seq: max(state.last_cancel_seq, seq)}}
  end

  def handle_cast({:acp_session_cancel, _seq}, %{turn: {:prompting, t}} = state),
    do: {:noreply, begin_cancel(state, t, true)}

  def handle_cast({:acp_session_cancel, _seq}, state), do: {:noreply, state}

  # The peer abandoned the prompt id with `$/cancel_request`: cancel, and send
  # no response frame.
  @impl true
  def handle_info(
        {:acp_reply_cancelled, rref},
        %{turn: {:prompting, %{reply_ref: rref} = t}} = state
      ),
      do: {:noreply, begin_cancel(state, t, false)}

  def handle_info(
        {:acp_reply_cancelled, rref},
        %{turn: {:cancelling, %{reply_ref: rref} = t}} = state
      ),
      do: {:noreply, %{state | turn: {:cancelling, %{t | respond?: false}}}}

  def handle_info({:acp_reply_cancelled, _rref}, state), do: {:noreply, state}

  def handle_info({:acp_result, tag, result}, %{turn: {ts, t}} = state) do
    case Map.pop(t.pending_perms, tag) do
      {nil, _} ->
        Logger.debug("dropping stale permission result for #{inspect(state.session_id)}")
        {:noreply, state}

      {%{from: from}, rest} ->
        GenServer.reply(from, Turn.permission_result(result))
        {:noreply, %{state | turn: {ts, %{t | pending_perms: rest}}}}
    end
  end

  # The runner ignored `:acp_cancel`: kill the group; the DOWNs drain it.
  def handle_info({:cancel_backstop, ref}, %{turn: {:cancelling, %{turn_ref: ref} = t}} = state) do
    Enum.each(t.monitors, fn {_ref, pid} -> Process.exit(pid, :kill) end)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{turn: {ts, t}} = state)
      when is_reference(ref) and is_map_key(t.monitors, ref) do
    Process.demonitor(ref, [:flush])
    t = Turn.drop_monitor(t, ref)
    t = if ref == t.root_ref, do: Turn.fold_root(t, result), else: t
    {:noreply, drain_check(%{state | turn: {ts, t}})}
  end

  # A subagent crash is not a turn crash; only the root's outcome counts.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{turn: {ts, t}} = state)
      when is_map_key(t.monitors, ref) do
    t = Turn.drop_monitor(t, ref)
    t = if ref == t.root_ref and reason != :normal, do: Turn.fold_crash(t), else: t
    {:noreply, drain_check(%{state | turn: {ts, t}})}
  end

  # The epoch match proves no activity re-armed the timer since.
  def handle_info({:acp_idle_reap, epoch}, %{turn: :idle, idle_epoch: epoch} = state) do
    Logger.debug("acp: idle-reaping session #{inspect(state.session_id)} after idle timeout")
    Telemetry.execute([:raxol, :acp, :session_idle_reaped], %{session_id: state.session_id})
    if function_exported?(state.emitter, :reap, 1), do: state.emitter.reap(state)
    {:stop, :normal, %{state | idle_timer: nil}}
  end

  # Stale timers, late results and unknown messages.
  def handle_info(_other, state), do: {:noreply, state}

  # -- Turn lifecycle ---------------------------------------------------------

  # With several connections attached to one session_id there is one Session
  # per connection; the journal Writer's turn latch arbitrates between them.
  defp start_turn(state, req, reply_ref, rx_seq) do
    turn_seq = state.turn_seq + 1

    case state.emitter.turn_started(state, req, turn_seq) do
      {:error, :turn_in_flight} ->
        _ = state.conn_mod.reply(state.conn, reply_ref, {:error, busy()})
        arm_idle(state)

      _ok ->
        session = self()

        task =
          Task.Supervisor.async_nolink(state.task_sup, fn -> state.turn_runner.(session, req) end)

        disarm_idle(%{
          state
          | turn: {:prompting, Turn.new(task, reply_ref, rx_seq, req)},
            turn_seq: turn_seq,
            steer_state: state.steer_adapter.turn_started(state.steer_state, turn_seq)
        })
    end
  end

  defp busy, do: Error.new(-32_600, "prompt already in flight")

  # Overwrites the outcome with `cancelled`, denies open asks, interrupts the
  # root task and arms the turn-ref-guarded backstop. Clearing the steer token
  # makes steers during cancellation reject with `:no_live_turn`.
  @spec begin_cancel(t(), Turn.t(), boolean()) :: t()
  defp begin_cancel(state, t, respond?) do
    abort_pending_perms(state, t)
    if t.root_pid, do: send(t.root_pid, :acp_cancel)

    timer =
      Process.send_after(self(), {:cancel_backstop, t.turn_ref}, state.config.cancel_backstop_ms)

    t = %{
      t
      | outcome: {:stop, :cancelled},
        pending_perms: %{},
        respond?: respond?,
        backstop_timer: timer
    }

    drain_check(%{
      state
      | turn: {:cancelling, t},
        steer_state: state.steer_adapter.turn_ended(state.steer_state)
    })
  end

  @spec drain_check(t()) :: t()
  defp drain_check(%{turn: {_ts, t}} = state),
    do: if(Turn.drained?(t), do: finish(state, t), else: state)

  @spec abort_pending_perms(t(), Turn.t()) :: :ok
  defp abort_pending_perms(state, t) do
    Enum.each(t.pending_perms, fn {tag, %{from: from}} ->
      GenServer.reply(from, {:ok, :cancelled})
      _ = state.conn_mod.cancel_request(state.conn, tag)
    end)
  end

  # The one render feeds both the journal's `turn_completed` and the reply.
  # `reply/3` is sent even when `respond?` is false: the Connection must release
  # the entry, and it suppresses the frame for a cancelled id itself.
  @spec finish(t(), Turn.t()) :: t()
  defp finish(state, t) do
    if t.backstop_timer, do: Process.cancel_timer(t.backstop_timer)
    # Asks from processes outside the task group may still be parked.
    abort_pending_perms(state, t)
    warn_if_silent(state, t)
    rendered = Turn.render(t.outcome)
    _ = state.emitter.turn_completed(state, rendered, state.turn_seq)
    _ = state.conn_mod.reply(state.conn, t.reply_ref, rendered)

    arm_idle(%{
      state
      | turn: :idle,
        steer_state: state.steer_adapter.turn_ended(state.steer_state)
    })
  end

  # A conformance problem in the agent, so it is reported, not papered over.
  defp warn_if_silent(state, t) do
    case Turn.silent_completion(t) do
      nil ->
        :ok

      reason ->
        Logger.warning(
          "ACP: turn for session #{inspect(state.session_id)} completed " <>
            "(stopReason: #{inspect(reason)}) with zero session/update notifications " <>
            "for a non-empty prompt"
        )

        Telemetry.execute([:raxol, :acp, :zero_updates_turn], %{
          session_id: state.session_id,
          stop_reason: reason
        })
    end
  end

  # The adapter only accepts during a live turn; the guard covers races.
  @spec steer_accepted(t(), map(), SteerAdapter.request()) :: t()
  defp steer_accepted(%{turn: {:prompting, t}} = state, ref, request) do
    send(t.root_pid, {:acp_steer, Map.get(request, :text)})

    if function_exported?(state.emitter, :steer_accepted, 3),
      do: state.emitter.steer_accepted(state, ref, request)

    state
  end

  defp steer_accepted(state, _ref, _request), do: state

  defp valid_mode?(nil, _mode_id), do: false

  defp valid_mode?(%SessionModeState{available_modes: modes}, mode_id),
    do: Enum.any?(modes, &(&1.id == mode_id))

  defp normalize_config(config) do
    config = Map.new(config)

    %{
      permission_timeout: Map.get(config, :permission_timeout, @default_permission_timeout),
      cancel_backstop_ms: Map.get(config, :cancel_backstop_ms, @default_cancel_backstop_ms),
      idle_timeout: Map.get(config, :idle_timeout, @default_idle_timeout)
    }
  end

  # -- Idle reaping -----------------------------------------------------------

  # Every arm bumps the epoch, so a timer from an earlier idle window is inert.
  @spec arm_idle(t()) :: t()
  defp arm_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)

    case state.config.idle_timeout do
      :infinity ->
        %{state | idle_timer: nil}

      ms when is_integer(ms) and ms > 0 ->
        epoch = state.idle_epoch + 1

        %{
          state
          | idle_timer: Process.send_after(self(), {:acp_idle_reap, epoch}, ms),
            idle_epoch: epoch
        }
    end
  end

  @spec disarm_idle(t()) :: t()
  defp disarm_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil, idle_epoch: state.idle_epoch + 1}
  end
end

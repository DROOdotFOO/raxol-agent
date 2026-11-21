defmodule Raxol.Agent.Session do
  @moduledoc """
  Manages a single agent's TEA application lifecycle.

  Follows the same pattern as `Raxol.SSH.Session`: wraps a Lifecycle
  instance with `environment: :agent`. Agents register in
  `Raxol.Agent.Registry` for discovery by other agents.

  ## Agent turns

  The session runs the agent turn contract (see `Raxol.Agent.Comm`) and
  intercepts these messages instead of forwarding them to the agent, with
  or without `:from` metadata:

    * `{:call, pid, ref, {:acp_prompt, text, approver}}` - a prompt. The
      agent receives it with this session as the caller and a ref the
      session made for the turn, never `ref`. An envelope whose `pid` is not
      a pid or whose `ref` is not a reference is dropped.
    * `{:acp_cancel, ref}` - cancels the in-flight turn whose caller named
      it `ref`. One that names no in-flight turn is swallowed, so an agent
      cannot use this shape for its own messages.
    * `{:call, pid, call_ref, {:acp_cancel, ref}}` - the same cancel,
      answered `:ok` or `{:error, :not_found}` to `pid`.

  This `{:acp_cancel, ref}` is not the bare `:acp_cancel` atom of the ACP
  stack, which `Raxol.AgentClientProtocol.Session` sends to the process
  running a `Raxol.Agent.ClientProtocol.Turn` turn. The session neither
  sends nor intercepts that atom.

  A cancelled turn is answered `{:error, :cancelled}`, but a change its
  process already sent to the agent is not rolled back. The turn's process
  first gets an exit signal it can trap, then is killed (see
  `Raxol.Agent.Comm.run_turn/3`).

  ## The turn in the journal

  The Dispatcher brackets each fold of `update/2`, which for a turn that runs
  in its own process ends long before the turn does. So the session brackets
  the whole turn under a turn id of its own (`acp-...`): a durable
  `turn_started` (payload `prompt`) when the prompt is accepted, then exactly
  one of `turn_completed` (the turn was answered), `turn_canceled` (payload
  `reason`: `cancelled`, or `caller_down` when the prompt's caller exited) or
  `error` (payload `reason`: `turn_failed`, or `agent_down` when a standalone
  session's agent went down). A session that dies mid-turn leaves the
  `turn_started` open; a journal reopened with `journal_required: true`
  closes it (see `Raxol.Agent.EmitBridge`).

  The turn's agent ref is not a secret inside the node: it travels in the
  Dispatcher's durable `:turn_started` event (with the prompt) and in the
  journal, so any process that reads those can answer or message the turn.
  The node is the trust boundary; the caller's own ref can only cancel.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Agent.Comm
  alias Raxol.Agent.SemanticTree
  alias Raxol.Agent.Session.Companions
  alias Raxol.Agent.Session.InFlightTurns
  alias Raxol.Agent.Session.PromptTurn
  alias Raxol.Agent.Session.Registration

  @registry Raxol.Agent.Registry

  defstruct [
    :id,
    :app_module,
    :lifecycle_pid,
    :lifecycle_mref,
    :team_id,
    :session_id,
    :emit_bridge,
    bridge_opts: [],
    owns_bridge?: true,
    owns_lifecycle?: true,
    turns: %{},
    agent_refs: %{},
    monitors: %{}
  ]

  @type t :: %__MODULE__{
          id: term(),
          app_module: module(),
          lifecycle_pid: pid() | nil,
          lifecycle_mref: reference() | nil,
          team_id: term() | nil,
          session_id: String.t() | nil,
          emit_bridge: pid() | nil,
          bridge_opts: keyword(),
          owns_bridge?: boolean(),
          owns_lifecycle?: boolean(),
          turns: %{reference() => InFlightTurns.turn()},
          agent_refs: %{reference() => reference()},
          monitors: %{reference() => reference()}
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      # Must exceed `Companions.stop_budget_ms/0`: a standalone session stops
      # its lifecycle in `terminate/2`, and a parent that killed it first
      # would orphan the lifecycle.
      shutdown: Companions.stop_budget_ms() + 1_000
    }
  end

  @doc """
  Start a standalone session. `journal_required: true` raises `ArgumentError`
  here: a standalone session carries on without its bridge, so only
  `Raxol.Agent.Session.Supervisor.start_session/2` can require a journal.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    if Keyword.get(opts, :journal_required, false) == true and
         Keyword.get(opts, :start_emit_bridge, true) do
      raise ArgumentError,
            ":journal_required needs Raxol.Agent.Session.Supervisor.start_session/2; " <>
              "a standalone session cannot refuse to run unjournaled"
    end

    # A `:rest_for_one` restart can race Registry's cleanup of the dead
    # predecessor's name.
    Registration.await_free(id)

    # The `:session` value tells agent sessions apart from the `{:lifecycle, _}`
    # and `{:emit_bridge, _}` entries in the same Registry.
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, id, :session}})
  end

  @doc """
  Send a message into the agent's TEA loop.

  Pass `from: sender_agent_id` to attribute the message; it arrives in
  `update/2` as `{:agent_message, sender_agent_id, message}`. Without it
  the `from` position is `nil` (unknown sender), never a guess.
  """
  @spec send_message(term(), term(), keyword()) :: :ok | {:error, :not_found}
  def send_message(agent_id, message, opts \\ []) do
    with {:ok, pid} <- whereis(agent_id) do
      case Keyword.get(opts, :from) do
        nil -> GenServer.cast(pid, {:send_message, message})
        from -> GenServer.cast(pid, {:send_message, message, %{from: from}})
      end
    end
  end

  @doc "Read the agent's current model."
  @spec get_model(term()) :: {:ok, term()} | {:error, term()}
  def get_model(agent_id), do: call(agent_id, :get_model)

  @doc "Read the agent's latest view tree."
  @spec get_view_tree(term()) :: {:ok, term()} | {:error, term()}
  def get_view_tree(agent_id), do: call(agent_id, :get_view_tree)

  @doc "Read the agent's view as a semantic tree (layout keys stripped)."
  @spec get_semantic_view(term()) :: {:ok, term()} | {:error, term()}
  def get_semantic_view(agent_id), do: call(agent_id, :get_semantic_view)

  @doc "Read the harness session_id for a running agent."
  @spec session_id(term()) :: {:ok, String.t() | nil} | {:error, :not_found}
  def session_id(agent_id), do: call(agent_id, :get_session_id)

  defp call(agent_id, request) do
    with {:ok, pid} <- whereis(agent_id), do: GenServer.call(pid, request)
  end

  defp whereis(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # Two ownership modes. Standalone (the default), the session starts its
  # bridge and lifecycle unlinked, monitors them and stops them in
  # `terminate/2`, which needs `trap_exit`. Under `Session.Supervisor`
  # (`start_emit_bridge: false`, `manage_lifecycle: false`) both are
  # `:rest_for_one` siblings started before the session, which only looks
  # them up; a crash of either restarts the session too.
  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.get(opts, :team_id)
    session_id = Keyword.get(opts, :session_id) || Registration.derive_session_id(id)

    bridge_opts =
      opts
      |> Keyword.take([:journal, :journal_opts])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    owns_bridge? = Keyword.get(opts, :start_emit_bridge, true)
    owns_lifecycle? = Keyword.get(opts, :manage_lifecycle, true)

    if owns_bridge? or owns_lifecycle?, do: Process.flag(:trap_exit, true)

    # The bridge first, so it is subscribed to EmitBus before the first turn.
    emit_bridge =
      if owns_bridge?,
        do: start_monitored_bridge(session_id, bridge_opts),
        else: Companions.lookup_bridge(session_id)

    Registration.register(session_id, id, app_module, team_id)

    {lifecycle_pid, lifecycle_mref} =
      if owns_lifecycle? do
        pid = Companions.start_owned(app_module, id, session_id)
        {pid, Process.monitor(pid)}
      else
        {Companions.lookup(session_id), nil}
      end

    Logger.info(
      "[Agent.Session] Started agent #{inspect(id)} (#{inspect(app_module)}) session=#{session_id}"
    )

    {:ok,
     %__MODULE__{
       id: id,
       app_module: app_module,
       lifecycle_pid: lifecycle_pid,
       lifecycle_mref: lifecycle_mref,
       team_id: team_id,
       session_id: session_id,
       emit_bridge: emit_bridge,
       bridge_opts: bridge_opts,
       owns_bridge?: owns_bridge?,
       owns_lifecycle?: owns_lifecycle?
     }}
  end

  defp start_monitored_bridge(session_id, bridge_opts) do
    bridge = Companions.start_bridge(session_id, bridge_opts)
    if bridge, do: Process.monitor(bridge)
    bridge
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:send_message, message}, state),
    do: handle_manager_cast({:send_message, message, %{}}, state)

  # Filtered for both cast shapes, so attributed sends cannot carry a foreign
  # team's broadcast past it.
  def handle_manager_cast(
        {:send_message, {:team_broadcast, team_id, _} = message, metadata},
        state
      )
      when is_map(metadata) do
    if state.team_id == team_id,
      do: {:noreply, InFlightTurns.forward(state, message, metadata)},
      else: {:noreply, state}
  end

  # A prompt is a turn in either shape: passed through, it would hand the
  # agent's turn to the sender, outside the session.
  def handle_manager_cast(
        {:send_message, {:call, caller, ref, {:acp_prompt, text, approver}}, metadata},
        state
      )
      when is_pid(caller) and is_reference(ref) and is_map(metadata) do
    {:noreply, InFlightTurns.start(state, caller, ref, text, approver, metadata)}
  end

  # Unanswerable, and passed through it would reach `update/2` and the logs
  # with its text.
  def handle_manager_cast({:send_message, {:call, _, _, {:acp_prompt, _, _}}, metadata}, state)
      when is_map(metadata) do
    Logger.warning(
      "[Agent.Session] #{inspect(state.id)} dropped a prompt whose caller is not a " <>
        "pid or whose ref is not a reference"
    )

    {:noreply, state}
  end

  def handle_manager_cast({:send_message, {:acp_cancel, ref}, metadata}, state)
      when is_map(metadata) do
    {_result, state} = InFlightTurns.cancel(state, ref, metadata)
    {:noreply, state}
  end

  def handle_manager_cast(
        {:send_message, {:call, caller, call_ref, {:acp_cancel, ref}}, metadata},
        state
      )
      when is_pid(caller) and is_reference(call_ref) and is_map(metadata) do
    {result, state} = InFlightTurns.cancel(state, ref, metadata)
    Comm.reply(caller, call_ref, result)
    {:noreply, state}
  end

  def handle_manager_cast({:send_message, message, metadata}, state) when is_map(metadata),
    do: {:noreply, InFlightTurns.forward(state, message, metadata)}

  def handle_manager_cast(_msg, state), do: {:noreply, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_session_id, _from, state),
    do: {:reply, {:ok, state.session_id}, state}

  def handle_manager_call(request, _from, state)
      when request in [:get_model, :get_view_tree, :get_semantic_view] do
    result =
      case Companions.dispatcher(state.lifecycle_pid) do
        nil -> {:error, :no_dispatcher}
        pid -> dispatcher_call(pid, request)
      end

    {:reply, result, state}
  end

  def handle_manager_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}

  defp dispatcher_call(pid, :get_semantic_view) do
    with {:ok, tree} <- GenServer.call(pid, :get_view_tree),
         do: {:ok, SemanticTree.from_view_tree(tree)}
  end

  defp dispatcher_call(pid, request), do: GenServer.call(pid, request)

  # Messages from the agent and its turn processes name the turn by its
  # agent ref. One naming a ref no longer in `agent_refs`, or a caller's ref,
  # falls through to the catch-all and is dropped.
  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:agent_reply, agent_ref, reply}, %__MODULE__{agent_refs: refs} = state)
      when is_map_key(refs, agent_ref),
      do: {:noreply, InFlightTurns.reply(state, agent_ref, reply)}

  def handle_manager_info(
        {:acp_turn_reply, agent_ref, owner, reply},
        %__MODULE__{agent_refs: refs} = state
      )
      when is_map_key(refs, agent_ref),
      do: {:noreply, InFlightTurns.finish(state, agent_ref, owner, reply)}

  def handle_manager_info({:acp_run, agent_ref, fun}, %__MODULE__{agent_refs: refs} = state)
      when is_map_key(refs, agent_ref) and is_function(fun, 0),
      do: {:noreply, InFlightTurns.run(state, agent_ref, fun)}

  def handle_manager_info(
        {:acp_turn_message, agent_ref, message},
        %__MODULE__{agent_refs: refs} = state
      )
      when is_map_key(refs, agent_ref),
      do: {:noreply, InFlightTurns.message(state, agent_ref, message)}

  def handle_manager_info(
        {:acp_turn_failed, agent_ref, owner},
        %__MODULE__{agent_refs: refs} = state
      )
      when is_map_key(refs, agent_ref),
      do: {:noreply, InFlightTurns.failed(state, agent_ref, owner)}

  # A crashed bridge is restarted under the same session id; a graceful stop
  # means the session is usually terminating too.
  def handle_manager_info(
        {:DOWN, _ref, :process, pid, reason},
        %__MODULE__{emit_bridge: pid} = state
      ) do
    if reason in [:normal, :shutdown] do
      {:noreply, %{state | emit_bridge: nil}}
    else
      Logger.warning(
        "[Agent.Session] EmitBridge for session #{state.session_id} crashed: " <>
          "#{inspect(reason)}; restarting"
      )

      {:noreply,
       %{state | emit_bridge: start_monitored_bridge(state.session_id, state.bridge_opts)}}
    end
  end

  # Matched on the monitor ref only this session holds, not the lifecycle pid
  # any in-node process can learn. A tree-owned lifecycle has no monitor.
  def handle_manager_info(
        {:DOWN, mref, :process, _pid, reason},
        %__MODULE__{lifecycle_mref: mref} = state
      )
      when is_reference(mref) do
    Logger.warning(
      "[Agent.Session] Lifecycle for #{inspect(state.id)} crashed: " <>
        PromptTurn.failure_shape(reason)
    )

    {:noreply, %{InFlightTurns.agent_down(state) | lifecycle_pid: nil, lifecycle_mref: nil}}
  end

  # A monitor no longer in `monitors` (its turn ended) falls to the
  # catch-all, which spares a mailbox-scanning `:flush` on every demonitor.
  def handle_manager_info(
        {:DOWN, mref, :process, _pid, reason},
        %__MODULE__{monitors: monitors} = state
      )
      when is_map_key(monitors, mref),
      do: {:noreply, InFlightTurns.down(state, mref, reason)}

  # Standalone mode traps exits. gen_server handles the parent's exit itself,
  # so this is a non-parent link.
  def handle_manager_info({:EXIT, pid, reason}, state) when reason not in [:normal, :shutdown] do
    Logger.warning(
      "[Agent.Session] linked process #{inspect(pid)} for #{inspect(state.id)} " <>
        "exited abnormally: #{inspect(reason)}"
    )

    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # Standalone mode only; under `Session.Supervisor` the tree stops both.
  # The lifecycle is stopped first and synchronously, so the bridge drains
  # what it published while stopping.
  @impl GenServer
  def terminate(_reason, state) do
    if state.owns_lifecycle?, do: Companions.stop(state.lifecycle_pid)
    if state.owns_bridge?, do: Companions.stop_bridge(state.emit_bridge)
    :ok
  end
end

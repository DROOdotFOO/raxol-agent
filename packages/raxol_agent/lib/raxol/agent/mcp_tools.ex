defmodule Raxol.Agent.McpTools do
  @moduledoc """
  Raxol agents as MCP tools: a client starts agents in this BEAM, asks them,
  and stops them. They live as long as the BEAM; their journals persist.

    * `agent_spawn {app, id}` - start an allowlisted app as agent `id`
    * `agent_list` - the agents this server answers for, and the apps it starts
    * `agent_ask {id, message, timeout_ms}` - `Raxol.Agent.Comm.call/3`
    * `agent_status {id}`, `agent_stop {id}`
    * resource `raxol://agent/<id>/journal` - the agent's journal

  `agent_spawn`, `agent_ask` and `agent_stop` are annotated `sensitive`. The
  annotation is advisory: a server with an authorizer that allows them, as
  `raxol mcp` has, asks no one before running them.

  ## Registration

  This process registers the tools with `Raxol.MCP.Registry` and owns them,
  so they leave the registry with it. Whether it registers is decided once
  per BEAM, when `Raxol.Agent.McpTools` first starts, and a restart repeats
  that decision. It registers if the registry is running then and
  `config :raxol_agent, :mcp_tools` allows it:

    * unset - only on a node whose startup mode is `:mcp` (`raxol mcp`,
      `mix mcp.server`), as `Raxol.Application.health_status/0` reports it,
      and never when this process is started under `Raxol.Supervisor`
    * `true` - wherever the registry is running when this process starts
    * `false`, or any other value - never

  A `raxol` that starts `Raxol.Agent.Supervisor` itself (2.7 and earlier, in
  `:full`) does so before the registry, so nothing registers there. This
  boolean is not the `mcp_tools:` option of
  `Raxol.Agent.Supervisor.start_link/1`, which carries this process's start
  options (the registry and server names).

  The setting is read at that first start, so it belongs in `config/*.exs`:
  `Application.put_env/3` after `:raxol_agent` has started changes nothing.
  The tools answer to the authorizer the node gives `Raxol.MCP.Server`
  (`config :raxol, :mcp_authorizer`), as every tool there does.

  ## Spawnable apps

  `config :raxol_agent, :mcp_spawnable_apps` lists the modules `agent_spawn`
  may start (default `[Raxol.Agent.Reference.Counter]`). The `app` argument is
  compared with their names as strings and never turned into an atom.

  ## Ownership

  The tools and the journal resource act only on agents this server started.
  A running agent carries that fact itself, as the `:owner` of its session
  tree (`Raxol.Agent.Session.Supervisor.owner/1`), so it survives a restart of
  this process and of the agent. An agent started some other way is refused,
  unless its id is in `config :raxol_agent, :mcp_exposed_agents` (a list of
  binary ids); such an id cannot be spawned. A team member is refused by
  `agent_status` and `agent_stop`.

  `start_owned/4` starts an agent under the same rules for another owner,
  as `raxol acp --agent` does. That agent is not this server's: the tools
  and the journal resource refuse it, and it shares only the id namespace
  and, for the same project root, the journal directory.

  An agent stopped through `agent_stop` leaves `agent_list` and, if this
  server started it, its id can be spawned again. Its journal stays readable
  until this process restarts: stopped agents are remembered in an ETS table
  it owns. While another owner runs an agent under a stopped id, that id is
  refused like any agent this server did not start: the journal directory
  then holds the other owner's records.

  Spawned ids share the node's agent registry with every other agent: a
  client can take any id nothing is registered under at that moment.

  ## Journals

  An agent is started with `journal_required: true` (see
  `Raxol.Agent.EmitBridge`): it does not start unless its journal is opened,
  private and locked. Journals live under
  `<sessions dir>/<first 8 hex of sha256(root)>/<id>` and record the project
  root and the app in `meta.json`; a journal recorded for another root or app
  is not continued. Spawning a stopped id continues its journal while the
  model starts from `init/1`.

  The root is the BEAM's working directory unless
  `config :raxol_agent, :mcp_project_root` names it (a path, or
  `{module, function, args}` returning `{:ok, path}`). Where one working
  directory serves several projects, they share journals: an `id` spawned in
  one continues the journal another wrote. `agent_spawn` and `agent_status`
  name the root in use.

  An exposed agent's journal is read from the default sessions directory
  under its session id, which is where it is unless that agent was started
  with another `:base_dir`.

  `agent_spawn` is refused on Windows, where the journal has no cross-process
  writer lock.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.McpTools.Handlers
  alias Raxol.Agent.McpTools.Ownership
  alias Raxol.Agent.McpTools.ToolDefinitions
  alias Raxol.Agent.Session
  alias Raxol.MCP.Registry, as: MCPRegistry
  alias Raxol.MCP.Server, as: MCPServer

  @registry Raxol.Agent.Registry

  # Lowercase only: an id is a directory name, and on a case-insensitive
  # volume `a` and `A` would be one journal.
  @id_format ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  # What a journal URI may name: a spawned id, or an exposed agent's.
  @uri_id_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @uri_prefix "raxol://agent/"
  @uri_suffix "/journal"
  @not_running "agents are not running in this server"

  @typedoc "A started agent: `continued` is the number of events its journal already held."
  @type started :: %{
          id: String.t(),
          app: module(),
          root: Path.t(),
          continued: non_neg_integer()
        }

  @doc """
  Start the server. `:registry` and `:server` name the `Raxol.MCP.Registry`
  it registers with and the `Raxol.MCP.Server` it notifies (default: the
  application's).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Start the allowlisted app named `app` as agent `id`, owned by this server.
  Returns the root the journal is bound to and `continued`, the number of
  events the journal already held.
  """
  @spec spawn_agent(String.t(), String.t()) :: {:ok, started()} | {:error, String.t()}
  def spawn_agent(app, id) when is_binary(app) and is_binary(id), do: call({:spawn, app, id})

  @doc "Stop agent `id` if this server started it or it is exposed."
  @spec stop_agent(String.t()) :: :ok | {:error, String.t()}
  def stop_agent(id) when is_binary(id), do: call({:stop, id})

  @doc """
  Start the allowlisted app named `app` as agent `id` for another owner,
  under the rules of `spawn_agent/2`, with its journal bound to `root`.

  The session tree's `:owner` is `{owner, %{app: module, root: root,
  base_dir: dir}}`, so this server does not list, ask, stop or serve the
  journal of the agent; `agent_spawn` refuses its id as in use while it
  runs. Runs in the caller, which nothing of the agent is linked to.
  """
  @spec start_owned(term(), String.t(), String.t(), Path.t()) ::
          {:ok, started()} | {:error, String.t()}
  def start_owned(owner, app, id, root)
      when owner != __MODULE__ and is_binary(app) and is_binary(id) and is_binary(root) do
    with {:ok, module} <- admit(app, id),
         {:ok, owned} <- start(owner, module, id, Path.expand(root)) do
      {:ok, started(id, owned)}
    end
  end

  @doc """
  Stop agent `id` if `owner` started it with `start_owned/4`. Returns once
  the id is free.
  """
  @spec stop_owned(term(), String.t()) :: :ok | {:error, :not_owned}
  def stop_owned(owner, id) when owner != __MODULE__ and is_binary(id) do
    case Session.Supervisor.owner(id) do
      {:ok, {^owner, _owned}} -> stop_tree(id, id)
      _other -> {:error, :not_owned}
    end
  end

  @doc "The names `agent_spawn` accepts as `app`."
  @spec spawnable() :: [String.t()]
  def spawnable do
    for module <- Application.get_env(:raxol_agent, :mcp_spawnable_apps, default_apps()),
        is_atom(module),
        do: inspect(module)
  end

  @doc "The journal resource URI of agent `id`."
  @spec journal_uri(String.t()) :: String.t()
  def journal_uri(id), do: @uri_prefix <> id <> @uri_suffix

  @doc "Whether `uri` is an agent journal URI (of any id)."
  @spec journal_uri?(term()) :: boolean()
  def journal_uri?(@uri_prefix <> rest) do
    String.ends_with?(rest, @uri_suffix) and
      Regex.match?(@uri_id_format, String.replace_suffix(rest, @uri_suffix, ""))
  end

  def journal_uri?(_uri), do: false

  @doc false
  @spec platform_refusal({atom(), atom()}) :: :ok | {:error, String.t()}
  def platform_refusal({:win32, _name}),
    do:
      {:error,
       "starting an agent is not available on Windows: the journal has no " <>
         "cross-process writer lock there"}

  def platform_refusal(_os_type), do: :ok

  @doc "The tool definitions."
  @spec tools() :: [map()]
  defdelegate tools, to: ToolDefinitions

  @impl GenServer
  def init(opts) do
    :ets.new(Ownership.table(), [:set, :protected, :named_table, read_concurrency: true])

    state = %{
      registry: Keyword.get(opts, :registry, Raxol.MCP.Registry),
      mcp_server: Keyword.get(opts, :server, Raxol.MCP.Server),
      registered?: false,
      published: MapSet.new()
    }

    # Agents this server started before a restart of this process are still
    # running, and still its own.
    running = for {id, agent} <- Ownership.owned_running(), do: Ownership.remember(id, agent)

    state = register(state)
    {:ok, Enum.reduce(running ++ Ownership.exposed(), state, &publish_journal(&2, &1, false))}
  end

  @impl GenServer
  def handle_call({:spawn, app, id}, _from, state) do
    case spawn_checked(app, id) do
      {:ok, started} -> {:reply, {:ok, started}, publish_journal(state, id, true)}
      {:error, _message} = refusal -> {:reply, refusal, state}
    end
  end

  def handle_call({:stop, id}, _from, state) do
    case Ownership.stoppable(id) do
      {:ok, agent} ->
        stop_tree(id, agent.session_id)
        Ownership.remember(id, agent)
        {:reply, :ok, state}

      {:error, _message} = refusal ->
        {:reply, refusal, state}
    end
  end

  defp spawn_checked(app, id) do
    with {:ok, module} <- admit(app, id),
         {:ok, root} <- project_root(),
         {:ok, owned} <- start(__MODULE__, module, id, root) do
      Ownership.remember(id, Ownership.agent(id, owned))
      {:ok, started(id, owned)}
    end
  end

  # What every start must pass, whoever owns the agent.
  defp admit(app, id) do
    with :ok <- platform_refusal(:os.type()),
         :ok <- validate_id(id),
         :ok <- refuse_exposed(id),
         {:ok, module} <- spawnable_app(app),
         :ok <- id_free(id) do
      {:ok, module}
    end
  end

  # The registry forgets a stopped session a moment after it is gone, and the
  # id is free only then.
  defp stop_tree(id, session_id) do
    _ = Session.Supervisor.stop_session(session_id)
    Session.Registration.await_free(id)
    Session.Registration.await_free({:session_supervisor, session_id})
  end

  # `:registered?` decides whether a spawned agent's journal is published.
  defp register(state) do
    if register?(state.registry) and GenServer.whereis(state.registry) != nil do
      state.registry
      |> MCPRegistry.register_tools(tools(), owner: self())
      |> warn_on_refused_tools()

      # A client that listed tools while this process was down has none of them.
      MCPServer.notify(state.mcp_server, "notifications/tools/list_changed", %{})
      %{state | registered?: true}
    else
      state
    end
  end

  # Decided when this module first starts in the BEAM and repeated after, so
  # the tools a server offers do not depend on what has crashed since.
  defp register?(registry) do
    key = {__MODULE__, :register?, registry}

    case :persistent_term.get(key, nil) do
      nil ->
        # The registry first: it is not up yet when a `raxol` that starts
        # this process as its own child reaches it in a built-in mode.
        decision = GenServer.whereis(registry) != nil and wanted?()
        :persistent_term.put(key, decision)
        decision

      decision ->
        decision
    end
  end

  # Unset, the tools belong to a node booted to serve MCP. The mode comes
  # from `Raxol.Supervisor`, which cannot answer while it is starting this
  # process: started under it, the answer is no.
  defp wanted? do
    case Application.get_env(:raxol_agent, :mcp_tools) do
      nil -> not under_root_supervisor?() and Raxol.Application.health_status().mode == :mcp
      setting -> setting == true
    end
  end

  defp under_root_supervisor? do
    root = Process.whereis(Raxol.Supervisor)

    :"$ancestors"
    |> Process.get([])
    |> Enum.any?(&(&1 == Raxol.Supervisor or (is_pid(root) and &1 == root)))
  end

  defp warn_on_refused_tools(:ok), do: :ok

  defp warn_on_refused_tools({:error, {:name_collision, collisions}}) do
    Logger.warning(
      "[Agent.McpTools] tools refused (their client-side names are taken): " <>
        inspect(collisions)
    )
  end

  defp warn_on_refused_tools({:error, {:invalid_tool_name, name}}) do
    Logger.warning(
      "[Agent.McpTools] tools refused (a tool name is not a binary): #{inspect(name)}"
    )
  end

  # A resource registered while a call runs (`notify?`): the client is told
  # the list changed, as it is for tools.
  defp publish_journal(%{registered?: true} = state, id, notify?) do
    if MapSet.member?(state.published, id) do
      state
    else
      MCPRegistry.register_resources(state.registry, [journal_resource(id)], owner: self())

      if notify?,
        do: MCPServer.notify(state.mcp_server, "notifications/resources/list_changed", %{})

      %{state | published: MapSet.put(state.published, id)}
    end
  end

  defp publish_journal(state, _id, _notify?), do: state

  defp journal_resource(id) do
    %{
      uri: journal_uri(id),
      name: "Agent #{id} journal",
      description: "The last #{Handlers.journal_tail()} journal records of agent #{id}.",
      callback: fn -> Handlers.read_journal(id) end,
      fault?: &ToolDefinitions.fault?/1
    }
  end

  defp validate_id(id) do
    if Regex.match?(@id_format, id), do: :ok, else: {:error, ToolDefinitions.id_rule()}
  end

  # An exposed id belongs to whoever exposed it, running or not.
  defp refuse_exposed(id) do
    if id in Ownership.exposed(),
      do: {:error, "id #{id} is reserved for an agent this server exposes; pick another id"},
      else: :ok
  end

  defp spawnable_app(app) do
    modules = Application.get_env(:raxol_agent, :mcp_spawnable_apps, default_apps())

    case Enum.find(modules, &(is_atom(&1) and app in [inspect(&1), Atom.to_string(&1)])) do
      nil -> {:error, "app #{app} is not spawnable; spawnable: #{names(spawnable())}"}
      module -> {:ok, module}
    end
  end

  defp default_apps, do: [Raxol.Agent.Reference.Counter]

  defp names([]), do: "none"
  defp names(names), do: Enum.join(names, ", ")

  defp id_free(id) do
    case Registry.lookup(@registry, id) do
      [] -> :ok
      [_holder] -> {:error, in_use(id)}
    end
  rescue
    ArgumentError -> {:error, @not_running}
  end

  defp in_use(id) do
    case Ownership.team_of(id) do
      nil -> "id #{id} is in use; pick another id"
      team -> "id #{id} is in use (team #{team}); pick another id"
    end
  end

  defp project_root do
    case configured_root(Application.get_env(:raxol_agent, :mcp_project_root)) do
      {:ok, root} when is_binary(root) ->
        {:ok, Path.expand(root)}

      _unknown ->
        {:error, "the project root is not known (config :raxol_agent, :mcp_project_root)"}
    end
  end

  defp configured_root(nil), do: File.cwd()
  defp configured_root(root) when is_binary(root), do: {:ok, root}

  # Operator code, run in this process: its failure refuses the spawn.
  defp configured_root({module, function, args}) do
    apply(module, function, args)
  rescue
    error ->
      Logger.warning("[Agent.McpTools] :mcp_project_root raised #{inspect(error.__struct__)}")
      :error
  catch
    kind, _value ->
      Logger.warning("[Agent.McpTools] :mcp_project_root ended with #{kind}")
      :error
  end

  defp configured_root(_other), do: :error

  defp journal_base(root) do
    :sha256
    |> :crypto.hash(root)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
    |> FileStore.session_dir()
  end

  # Nothing here reads the journal directory: until the session's bridge has
  # vetted and locked it, it may be anything.
  defp start(owner, module, id, root) do
    owned = %{app: module, root: root, base_dir: journal_base(root)}

    started =
      Session.Supervisor.start_session(module,
        id: id,
        session_id: id,
        journal_required: true,
        journal_opts: [base_dir: owned.base_dir, cwd: root, title: inspect(module)],
        owner: {owner, owned}
      )

    case started do
      {:ok, _sup} -> {:ok, owned}
      {:error, reason} -> {:error, start_refusal(id, owned, reason)}
    end
  end

  defp started(id, owned),
    do: %{id: id, app: owned.app, root: owned.root, continued: continued(id)}

  # The offset the journal had reached, as the bridge that opened it found it.
  defp continued(id) do
    case Registry.lookup(@registry, {:emit_bridge, id}) do
      [{bridge, _value}] -> EmitBridge.prior_offset(bridge) || 0
      [] -> 0
    end
  catch
    :exit, _reason -> 0
  end

  defp start_refusal(id, owned, {:journal_locked, :lock_unavailable}),
    do:
      "no journal lock could be taken for #{id}, so it was not started: no " <>
        "`kill` binary was found, or #{Path.join(owned.base_dir, id)} is not writable " <>
        "or is on a volume without hard links"

  defp start_refusal(id, _owned, {:journal_locked, holder}) do
    if holder == System.pid(),
      do: "journal #{id} is still open in this server; ask again",
      else:
        "another running server (pid #{holder}) holds journal #{id}; " <>
          "stop it or spawn under another id"
  end

  defp start_refusal(id, _owned, {:journal_bound, %{field: :cwd, journal: root}}),
    do: "journal #{id} belongs to project root #{root || "(none recorded)"}; pick another id"

  defp start_refusal(id, _owned, {:journal_bound, %{field: :title, journal: app}}),
    do: "journal #{id} belongs to app #{app || "(none recorded)"}; pick another id"

  defp start_refusal(id, _owned, {:journal_damaged, _session}),
    do: "journal #{id} is damaged and is not continued; pick another id"

  defp start_refusal(id, _owned, {:already_started, _pid}), do: in_use(id)
  defp start_refusal(_id, _owned, :registry_not_running), do: @not_running
  defp start_refusal(_id, _owned, :dynsup_not_running), do: @not_running

  defp start_refusal(id, _owned, reason) do
    Logger.warning("[Agent.McpTools] agent #{id} did not start: #{inspect(reason)}")
    "agent #{id} did not start; the server log has the reason"
  end

  defp call(request) do
    GenServer.call(__MODULE__, request, :infinity)
  catch
    :exit, {:noproc, _call} -> {:error, @not_running}
  end
end

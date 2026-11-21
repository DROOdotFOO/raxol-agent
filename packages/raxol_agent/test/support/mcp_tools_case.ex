defmodule Raxol.Agent.McpToolsCase do
  @moduledoc """
  Case template for the `Raxol.Agent.McpTools` suites. Each test gets its
  own `Raxol.MCP.Registry` and `Raxol.MCP.Server` (unless tagged
  `mcp: false`), a project root, and McpTools started bare or, when tagged
  `supervisor: true`, under `Raxol.Agent.Supervisor`. Tags `mode:` and
  `env:` set the startup mode and `:raxol_agent` env.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.MCP.Authorizer
  alias Raxol.MCP.Server

  using do
    quote do
      import Raxol.Agent.McpToolsCase

      @moduletag :capture_log
      @moduletag :unix_only

      @counter "Raxol.Agent.Reference.Counter"
      @silent "Raxol.Agent.SilentAgent"
      @with_silent [
        mcp_spawnable_apps: [Raxol.Agent.Reference.Counter, Raxol.Agent.SilentAgent]
      ]
    end
  end

  setup context do
    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})
    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    # Names of this test's own: the registry caches its table by name.
    registry = :"mcp_tools_registry_#{uniq()}"
    server = :"mcp_tools_server_#{uniq()}"
    Process.put(:mcp, {registry, server})

    if Map.get(context, :mcp, true), do: start_mcp()

    root = tmp_dir("mcp_tools_root")
    put_env(:mcp_project_root, root)
    # Unset, the tools register on a node booted for MCP, as `raxol mcp` is.
    delete_env(:mcp_tools)
    put_startup_mode(Map.get(context, :mode, :mcp))
    for {key, value} <- Map.get(context, :env, []), do: put_env(key, value)

    if Map.get(context, :supervisor, false) do
      start_supervised!({Raxol.Agent.Supervisor, mcp_tools: [registry: registry, server: server]})
    else
      start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
      start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})
      start_supervised!(Raxol.Agent.SessionStreamer)
      start_supervised!({McpTools, registry: registry, server: server})
    end

    %{root: root, id: "a#{uniq()}", registry: registry, server: server}
  end

  @doc false
  def no_root, do: {:error, :unknown}

  @doc false
  def raising_root, do: raise("no root today")

  def start_mcp do
    {registry, server} = Process.get(:mcp)
    start_supervised!({Raxol.MCP.Registry, name: registry, server: server})

    start_supervised!(
      {Server,
       name: server,
       registry: registry,
       authorizer: Authorizer.allow_all(),
       read_authorizer: Authorizer.allow_all()}
    )
  end

  @doc "Kill a process and return once it is down."
  def crash(process) do
    pid = GenServer.whereis(process)
    mref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 5_000
  end

  # Wait for what `supervisor` does about a dead child: each round is one call
  # the supervisor answers only after the messages before it, its child's exit
  # and its own restart attempts among them.
  def await(done?, supervisor, rounds \\ 2_000) do
    _ = :sys.get_state(supervisor)

    cond do
      done?.() -> :ok
      rounds == 0 -> flunk("#{inspect(supervisor)} did not restart its child")
      true -> await(done?, supervisor, rounds - 1)
    end
  end

  def agent_tools do
    {registry, _server} = Process.get(:mcp)
    for %{name: "agent_" <> _ = name} <- Raxol.MCP.Registry.list_tools(registry), do: name
  end

  def resource_uris do
    {registry, _server} = Process.get(:mcp)
    Enum.map(Raxol.MCP.Registry.list_resources(registry), & &1.uri)
  end

  def call(tool, arguments) do
    {_registry, server} = Process.get(:mcp)

    {:reply, %{result: result}} =
      Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: uniq(),
        method: "tools/call",
        params: %{"name" => tool, "arguments" => arguments}
      })

    [%{type: "text", text: text}] = result.content
    if Map.get(result, :isError) == true, do: {:error, text}, else: {:ok, text}
  end

  def read(uri) do
    {_registry, server} = Process.get(:mcp)

    {:reply, reply} =
      Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: uniq(),
        method: "resources/read",
        params: %{"uri" => uri}
      })

    reply
  end

  def read_journal!(id) do
    %{result: %{contents: [%{text: json}]}} = read(McpTools.journal_uri(id))
    Jason.decode!(json)
  end

  @doc "An agent the MCP tools did not start."
  def start_directly(id, opts \\ []) do
    journal_opts = [base_dir: tmp_dir("mcp_tools_direct")]

    Session.Supervisor.start_session(
      Counter,
      Keyword.merge([id: id, session_id: id, journal_opts: journal_opts], opts)
    )
  end

  def journal_dir(root, id) do
    key = :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join([System.fetch_env!("RAXOL_SESSIONS_DIR"), key, id])
  end

  def rewrite_meta(root, id, fun) do
    path = Path.join(journal_dir(root, id), "meta.json")
    File.write!(path, path |> File.read!() |> Jason.decode!() |> fun.() |> Jason.encode!())
  end

  def turn_started(turn_id) do
    %{
      v: 0,
      session_id: "s",
      turn_id: turn_id,
      ts: 1,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{}
    }
  end

  def put_env(key, value) do
    restore_env(key)
    Application.put_env(:raxol_agent, key, value)
  end

  def delete_env(key) do
    restore_env(key)
    Application.delete_env(:raxol_agent, key)
  end

  def restore_env(key) do
    previous = Application.fetch_env(:raxol_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(:raxol_agent, key, was)
        :error -> Application.delete_env(:raxol_agent, key)
      end
    end)
  end

  # What `Raxol.Application.health_status/0` reports as the mode: `RAXOL_MODE`
  # beats `config :raxol, :startup_mode`, so the variable is cleared.
  def put_startup_mode(mode) do
    variable = System.get_env("RAXOL_MODE")
    configured = Application.fetch_env(:raxol, :startup_mode)
    System.delete_env("RAXOL_MODE")
    Application.put_env(:raxol, :startup_mode, mode)

    on_exit(fn ->
      if variable, do: System.put_env("RAXOL_MODE", variable)

      case configured do
        {:ok, was} -> Application.put_env(:raxol, :startup_mode, was)
        :error -> Application.delete_env(:raxol, :startup_mode)
      end
    end)
  end

  def tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  def uniq, do: System.unique_integer([:positive])

  def ensure_running({module, opts}) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end
end

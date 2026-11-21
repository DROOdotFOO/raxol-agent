defmodule Raxol.Agent.McpToolsJournalTest do
  @moduledoc """
  `Raxol.Agent.McpTools` journal binding (project root, app, writer lock),
  running under `Raxol.Agent.Supervisor`, and tool registration. A test
  tagged `supervisor: true` runs under the supervisor, where a crash of one
  child restarts the ones after it.
  """
  use Raxol.Agent.Test.McpToolsCase, async: false

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.Journal.Test.ForeignBeam

  @doc false
  def no_root, do: {:error, :unknown}

  @doc false
  def raising_root, do: raise("no root today")

  describe "the journal's project root and app" do
    test "another root gets a journal of its own", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})
      first = File.read!(Path.join(journal_dir(root, id), "journal/000001.jsonl"))

      other = tmp_dir("mcp_tools_other_root")
      put_env(:mcp_project_root, other)

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal root #{other}"
      assert text =~ "new journal"
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      assert journal_dir(other, id) != journal_dir(root, id)
      assert File.read!(Path.join(journal_dir(root, id), "journal/000001.jsonl")) == first
    end

    test "a journal recorded for another root is refused", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      # What a second root hashing to the same directory would find.
      rewrite_meta(root, id, &Map.put(&1, "cwd", "/another/project"))

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal #{id} belongs to project root /another/project; pick another id"
      assert Session.Supervisor.whereis(id) == nil
      refute File.exists?(Path.join(journal_dir(root, id), "writer.lock"))
    end

    @tag env: @with_silent
    test "a journal recorded for another app is refused", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      assert {:error, text} = call("agent_spawn", %{"app" => @silent, "id" => id})
      assert text =~ "journal #{id} belongs to app #{@counter}; pick another id"
      assert Session.Supervisor.whereis(id) == nil

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued"
    end

    @tag env: [mcp_project_root: {__MODULE__, :no_root, []}]
    test "a project root that cannot be resolved refuses the spawn", %{id: id} do
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "the project root is not known"
      assert Session.Supervisor.whereis(id) == nil
    end

    @tag env: [mcp_project_root: {__MODULE__, :raising_root, []}]
    test "a project root function that raises refuses the spawn", %{id: id} do
      tools = Process.whereis(McpTools)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "the project root is not known"
      assert Process.whereis(McpTools) == tools
    end
  end

  describe "the journal lock" do
    test "a live BEAM holding the journal refuses the spawn", %{id: id, root: root} do
      base = Path.dirname(journal_dir(root, id))

      holder =
        ForeignBeam.start_supervised("""
        {:ok, _} = Application.ensure_all_started(:jason)
        {:ok, _} =
          Raxol.Agent.Journal.FileStore.open(#{inspect(id)},
            base_dir: #{inspect(base)},
            private: true,
            cwd: #{inspect(root)},
            title: #{inspect(@counter)}
          )
        """)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert text =~
               "another running server (pid #{holder.pid}) holds journal #{id}; " <>
                 "stop it or spawn under another id"

      refute text =~ "retry"
      assert Session.Supervisor.whereis(id) == nil
      assert Registry.lookup(Raxol.Agent.Registry, id) == []

      # Killed, it leaves its lock behind, which is then stale.
      :ok = ForeignBeam.kill(holder)
      assert File.exists?(Path.join(journal_dir(root, id), "writer.lock"))

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "started #{id}"
    end

    test "a journal this server still has open is not blamed on another server", %{
      id: id,
      root: root
    } do
      base = Path.dirname(journal_dir(root, id))

      {:ok, journal} =
        FileStore.open(id, base_dir: base, private: true, cwd: root, title: @counter)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal #{id} is still open in this server; ask again"
      refute text =~ "another running server"

      :ok = FileStore.close(journal)
      assert {:ok, _text} = call("agent_spawn", %{"app" => @counter, "id" => id})
    end

    test "a lock naming a dead pid is reclaimed", %{id: id, root: root} do
      dir = journal_dir(root, id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "writer.lock"), ForeignBeam.dead_pid())

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert [pid | _token] = dir |> Path.join("writer.lock") |> File.read!() |> String.split()
      assert pid == System.pid()
    end

    test "a journal that cannot be locked refuses the spawn", %{id: id, root: root} do
      # A directory where the lock's temp file belongs: no lock can be written.
      blocker = Path.join(journal_dir(root, id), "writer.lock.tmp.#{System.pid()}")
      File.mkdir_p!(blocker)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "no journal lock could be taken for #{id}"
      assert text =~ journal_dir(root, id)
      assert Session.Supervisor.whereis(id) == nil

      File.rmdir!(blocker)
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
    end
  end

  describe "under Raxol.Agent.Supervisor" do
    @describetag supervisor: true

    test "a restart of an earlier child keeps the agents", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      tools = Process.whereis(McpTools)
      session = Session.Supervisor.whereis(id)

      crash(Raxol.Agent.SessionStreamer)
      await(fn -> Process.whereis(McpTools) not in [nil, tools] end, Raxol.Agent.Supervisor)
      # Past its `init`: it answers.
      _ = :sys.get_state(McpTools)

      # The agent never stopped, and the restarted tools still answer for it.
      assert Session.Supervisor.whereis(id) == session
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [%{"id" => ^id, "app" => @counter}]} = Jason.decode!(listed)

      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      assert {:ok, "count: 2"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert %{"id" => ^id, "records" => [%{"type" => "agent_started"} | _]} = read_journal!(id)
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "is in use"

      assert {:ok, _} = call("agent_stop", %{"id" => id})
      assert Session.Supervisor.whereis(id) == nil
    end

    test "an agent whose session tree is killed comes back as this server's", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      [{tree, _}] = Registry.lookup(Raxol.Agent.Registry, {:session_supervisor, id})

      crash(tree)

      await(
        fn ->
          Session.Supervisor.whereis(id) != nil and
            Registry.lookup(Raxol.Agent.Registry, id) != []
        end,
        Raxol.Agent.DynSup
      )

      # Restarted from `init/1`, on the same journal, and still owned.
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, status} = call("agent_status", %{"id" => id})
      assert %{"state" => "running"} = Jason.decode!(status)

      assert {:ok, _} = call("agent_stop", %{"id" => id})
      assert Session.Supervisor.whereis(id) == nil

      started =
        id
        |> read_journal!()
        |> Map.fetch!("records")
        |> Enum.filter(&(&1["type"] == "agent_started"))

      assert [%{"payload" => %{"prior_offset" => 0}}, %{"payload" => %{"prior_offset" => prior}}] =
               started

      assert prior > 0
    end
  end

  describe "registration" do
    test "registers the five tools, owned by the server process", %{registry: registry} do
      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      owner = Process.whereis(McpTools)
      stop_supervised!(McpTools)
      :ok = Raxol.MCP.Registry.await_owner_cleanup(registry, owner)
      assert agent_tools() == []
    end

    @tag mcp: false
    test "runs with no tools where no MCP registry runs", %{id: id, root: root} = context do
      assert Process.whereis(context.registry) == nil

      assert {:ok, %{id: ^id, app: Counter, root: ^root, continued: 0}} =
               McpTools.spawn_agent(@counter, id)

      assert :ok = McpTools.stop_agent(id)
    end

    @tag mcp: false
    test "a registry that appears later changes nothing: the first start decided", context do
      start_mcp()
      stop_supervised!(McpTools)
      start_supervised!({McpTools, registry: context.registry, server: context.server})

      assert agent_tools() == []
    end

    @tag mode: :mcp
    test "unset, a node booted for MCP gets the tools and the journal resource", %{id: id} do
      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert resource_uris() == [McpTools.journal_uri(id)]
    end

    @tag mode: :full
    test "unset, a node in :full gets neither", %{id: id, registry: registry} do
      assert is_pid(Process.whereis(registry))
      assert agent_tools() == []

      assert {:ok, %{id: ^id}} = McpTools.spawn_agent(@counter, id)
      assert resource_uris() == []
    end

    @tag mode: :full, env: [mcp_tools: true]
    test "true registers them in :full", %{id: id} do
      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert resource_uris() == [McpTools.journal_uri(id)]
    end

    @tag mode: :mcp, env: [mcp_tools: false]
    test "false registers nothing on a node booted for MCP", %{id: id} do
      assert agent_tools() == []

      assert {:ok, %{id: ^id}} = McpTools.spawn_agent(@counter, id)
      assert resource_uris() == []
    end

    @tag mode: :full
    test "a setting put after the first start changes nothing", context do
      put_env(:mcp_tools, true)
      stop_supervised!(McpTools)
      start_supervised!({McpTools, registry: context.registry, server: context.server})

      assert agent_tools() == []
    end

    @tag mode: :mcp, mcp: false
    test "unset, a start under Raxol.Supervisor registers nothing and does not wait on it" do
      registry = :"mcp_tools_registry_#{uniq()}"
      server = :"mcp_tools_server_#{uniq()}"
      Process.put(:mcp, {registry, server})
      start_mcp()
      stop_supervised!(McpTools)

      spec = %{
        id: McpTools,
        start: {McpTools, :start_link, [[registry: registry, server: server]]},
        restart: :temporary
      }

      assert {:ok, _pid} = Supervisor.start_child(Raxol.Supervisor, spec)
      on_exit(fn -> Supervisor.terminate_child(Raxol.Supervisor, McpTools) end)

      assert agent_tools() == []
    end
  end
end

defmodule Raxol.Agent.McpToolsTest do
  @moduledoc """
  `Raxol.Agent.McpTools` through a real `Raxol.MCP.Server`: every call is a
  `tools/call` or `resources/read`, so the authorizer seam, the registry and
  the callback workers are the ones a client reaches. Spawning, asking,
  ownership, stopping and the journal resource.
  """
  use Raxol.Agent.Test.McpToolsCase, async: false

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Session
  alias Raxol.MCP.Server

  import Bitwise

  describe "agent_spawn" do
    test "starts an allowlisted app and lists it", %{id: id, root: root} do
      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "started #{id} (#{@counter})"
      assert text =~ "journal root #{root}"
      assert text =~ "new journal"

      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [agent], "spawnable" => spawnable} = Jason.decode!(listed)
      assert %{"id" => ^id, "app" => @counter, "root" => ^root, "team" => nil} = agent
      assert @counter in spawnable

      assert is_pid(Session.Supervisor.whereis(id))
    end

    test "refuses an app that is not listed and starts nothing", %{id: id} do
      for app <- ["Raxol.Agent.Session", "Elixir.System", "counter", @silent] do
        assert {:error, text} = call("agent_spawn", %{"app" => app, "id" => id})
        assert text =~ "is not spawnable"
        assert text =~ @counter
      end

      assert Session.Supervisor.whereis(id) == nil
      refute id in Enum.map(Session.Supervisor.list_sessions(), &elem(&1, 0))
      assert Registry.lookup(Raxol.Agent.Registry, id) == []
    end

    test "matches the app by name without making an atom of it", %{id: id} do
      name = "No.Such.App#{uniq()}"
      assert {:error, _refused} = call("agent_spawn", %{"app" => name, "id" => id})
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end

    test "refuses an id that is not a lowercase session id" do
      for id <- ["", "..", "a/b", "../x", ".hidden", "a b", "A1", "aB", String.duplicate("a", 65)] do
        assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
        assert text =~ "an id is 1-64 characters of a-z 0-9"
        assert Registry.lookup(Raxol.Agent.Registry, id) == []
      end

      assert {:error, _} = call("agent_spawn", %{"app" => @counter, "id" => 7})
    end

    test "refuses an id that is in use, naming its team", %{id: id} do
      {:ok, _} = start_directly(id, team_id: "t1")

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "id #{id} is in use (team t1); pick another id"

      other = "b#{uniq()}"
      {:ok, _} = start_directly(other)
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => other})
      assert text =~ "id #{other} is in use; pick another id"
    end

    @tag env: [mcp_exposed_agents: ["ops"]]
    test "refuses the id of an exposed agent, running or stopped" do
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => "ops"})
      assert text =~ "id ops is reserved"

      {:ok, _} = start_directly("ops")
      assert {:ok, _} = call("agent_stop", %{"id" => "ops"})

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => "ops"})
      assert text =~ "id ops is reserved"
      assert Registry.lookup(Raxol.Agent.Registry, "ops") == []
    end

    test "is refused on Windows, with the reason" do
      assert {:error, text} = McpTools.platform_refusal({:win32, :nt})
      assert text =~ "not available on Windows"
      refute text =~ "#"
      assert McpTools.platform_refusal({:unix, :darwin}) == :ok
      assert McpTools.platform_refusal({:unix, :linux}) == :ok
    end

    test "tells the client the resource list changed", %{id: id, server: server} do
      :ok = Server.subscribe(server, self())

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert_receive {:mcp_notification,
                      %{method: "notifications/resources/list_changed", params: %{}}},
                     5_000

      assert McpTools.journal_uri(id) in resource_uris()
    end

    test "keeps the journal directory to this account", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      for dir <- [journal_dir(root, id), Path.join(journal_dir(root, id), "journal")] do
        assert (File.stat!(dir).mode &&& 0o777) == 0o700
      end

      assert (File.stat!(Path.join(journal_dir(root, id), "meta.json")).mode &&& 0o777) == 0o600
    end

    test "survives the process that asked for it", %{id: id} do
      # The spawn is requested from a process that is gone before the next call.
      mcp = Process.get(:mcp)

      {asker, mref} =
        spawn_monitor(fn ->
          Process.put(:mcp, mcp)
          call("agent_spawn", %{"app" => @counter, "id" => id})
        end)

      assert_receive {:DOWN, ^mref, :process, ^asker, :normal}, 30_000

      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      # The ask was journaled: the journal was still open, and written to.
      types = id |> read_journal!() |> Map.fetch!("records") |> Enum.map(& &1["type"])
      assert hd(types) == "agent_started"
      assert "turn_started" in types
      assert "turn_completed" in types
    end

    test "a journal directory that cannot be read refuses the spawn and nothing else", %{
      id: id,
      root: root
    } do
      other = "b#{uniq()}"
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => other})
      tools = Process.whereis(McpTools)

      # A directory where the first segment file belongs.
      File.mkdir_p!(Path.join(journal_dir(root, id), "journal/000001.jsonl"))

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "agent #{id} did not start; the server log has the reason"
      refute text =~ "journal_open_failed"

      assert Process.whereis(McpTools) == tools
      assert Session.Supervisor.whereis(id) == nil
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => other, "message" => "increment"})
    end
  end

  describe "agent_ask" do
    test "round-trips a message and its reply", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, "count: 2"} = call("agent_ask", %{"id" => id, "message" => " increment "})
      assert {:ok, "count: 2"} = call("agent_ask", %{"id" => id, "message" => "get"})
      assert {:ok, help} = call("agent_ask", %{"id" => id, "message" => "reset"})
      assert help =~ "commands: increment, get"
    end

    @tag env: @with_silent
    test "names the timeout when the agent does not reply", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @silent, "id" => id})

      assert {:error, text} =
               call("agent_ask", %{"id" => id, "message" => "anyone?", "timeout_ms" => 1})

      assert text =~ "did not reply within 1 ms (timeout)"
    end

    test "refuses a timeout outside 1..25000", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      for timeout <- [0, 25_001, -1, "100", 1.5] do
        assert {:error, text} =
                 call("agent_ask", %{"id" => id, "message" => "get", "timeout_ms" => timeout})

        assert text =~ "timeout_ms is an integer from 1 to 25000"
      end
    end
  end

  describe "ownership" do
    test "an agent started another way is refused everywhere", %{id: id} do
      {:ok, _} = start_directly(id)

      for {tool, arguments} <- [
            {"agent_ask", %{"id" => id, "message" => "increment"}},
            {"agent_status", %{"id" => id}},
            {"agent_stop", %{"id" => id}}
          ] do
        assert {:error, text} = call(tool, arguments)
        assert text =~ "no agent #{id} was started by this server"
      end

      assert %{error: %{message: message}} = read(McpTools.journal_uri(id))
      assert message =~ "Resource not found"

      # Untouched: still running, never asked.
      assert {:ok, %{count: 0}} = Session.get_model(id)
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => []} = Jason.decode!(listed)
    end

    @tag env: [mcp_exposed_agents: ["shown"]]
    test "an exposed agent is answered for, and its journal handler checks again" do
      # Journaled where an agent started without options journals.
      {:ok, _} = start_directly("shown", journal_opts: [])

      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => "shown", "message" => "increment"})
      assert {:ok, status} = call("agent_status", %{"id" => "shown"})
      assert %{"state" => "running", "app" => @counter} = Jason.decode!(status)
      assert %{"id" => "shown", "records" => records} = read_journal!("shown")
      assert is_list(records)

      # The resource stays registered; the handler decides on each read.
      put_env(:mcp_exposed_agents, [])
      assert %{error: %{message: message}} = read(McpTools.journal_uri("shown"))
      assert message =~ "no agent shown was started by this server"
      assert {:error, _} = call("agent_stop", %{"id" => "shown"})

      put_env(:mcp_exposed_agents, ["shown"])
      assert {:ok, text} = call("agent_stop", %{"id" => "shown"})
      assert text =~ "its journal stays readable"
      assert Session.Supervisor.whereis("shown") == nil

      # Stopped, and what the stop said holds: the ask is in the journal.
      assert %{"id" => "shown", "records" => records} = read_journal!("shown")
      assert Enum.any?(records, &(&1["type"] == "turn_completed"))
      assert {:ok, status} = call("agent_status", %{"id" => "shown"})
      assert %{"state" => "stopped"} = Jason.decode!(status)

      put_env(:mcp_exposed_agents, [])
      assert %{error: %{message: message}} = read(McpTools.journal_uri("shown"))
      assert message =~ "no agent shown was started by this server"
    end

    @tag env: [mcp_exposed_agents: ["member"]]
    test "a team member is refused by status and stop" do
      {:ok, _} = start_directly("member", team_id: "t1")

      assert {:error, text} = call("agent_stop", %{"id" => "member"})
      assert text =~ "member belongs to team t1 and is not stopped from here"
      assert {:error, text} = call("agent_status", %{"id" => "member"})
      assert text =~ "member belongs to team t1 and is not reported from here"

      assert is_pid(Session.Supervisor.whereis("member"))
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [%{"id" => "member", "team" => "t1"}]} = Jason.decode!(listed)
    end

    @tag env: [mcp_exposed_agents: ["member"]]
    test "a refusal names no tool that is not registered", %{id: id} do
      {:ok, _} = start_directly("member", team_id: "t1")
      {:ok, _} = start_directly("taken")
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      refusals =
        for {tool, arguments} <- [
              {"agent_stop", %{"id" => "member"}},
              {"agent_status", %{"id" => "member"}},
              {"agent_spawn", %{"app" => @counter, "id" => "member"}},
              {"agent_spawn", %{"app" => @counter, "id" => "taken"}},
              {"agent_spawn", %{"app" => "nope", "id" => "x"}},
              {"agent_spawn", %{"app" => @silent, "id" => id}},
              {"agent_spawn", %{"app" => @counter, "id" => "Bad"}},
              {"agent_ask", %{"id" => id, "message" => "get"}},
              {"agent_ask", %{"id" => "nobody", "message" => "get"}},
              {"agent_stop", %{"id" => id}},
              {"agent_stop", %{}},
              {"agent_status", %{"id" => "nobody"}}
            ] do
          assert {:error, text} = call(tool, arguments)
          text
        end

      mentioned =
        refusals
        |> Enum.flat_map(&Regex.scan(~r/\b(?:agent|team)_[a-z_]+\b/, &1))
        |> List.flatten()
        |> Enum.uniq()

      assert "agent_spawn" in mentioned
      assert mentioned -- agent_tools() == []
    end
  end

  describe "agent_stop and the journal" do
    test "a stopped agent's journal stays readable", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})

      assert {:ok, text} = call("agent_stop", %{"id" => id})
      assert text =~ "stopped #{id}"
      assert Session.Supervisor.whereis(id) == nil

      assert %{"id" => ^id, "root" => ^root, "events" => events, "records" => records} =
               read_journal!(id)

      assert events == length(records)
      assert events > 1

      assert {:ok, status} = call("agent_status", %{"id" => id})
      dir = journal_dir(root, id)

      assert %{
               "state" => "stopped",
               "root" => ^root,
               "journal" => %{"events" => ^events, "dir" => ^dir}
             } = Jason.decode!(status)

      # Stopped: off the list, not askable, not stoppable twice.
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => []} = Jason.decode!(listed)
      assert {:error, text} = call("agent_ask", %{"id" => id, "message" => "get"})
      assert text =~ "agent #{id} is stopped"
      assert {:error, _} = call("agent_stop", %{"id" => id})
    end

    test "a respawn continues the journal and starts the state fresh", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      before = id |> read_journal!() |> Map.fetch!("records")
      last = List.last(before)["id"]

      # A turn the first run never closed: no checkpoint can be written.
      {:ok, journal} = FileStore.open(id, base_dir: Path.dirname(journal_dir(root, id)))
      {:ok, dangling} = FileStore.append(journal, turn_started("turn-left-open"))
      assert Checkpoint.write(journal, nil) == {:error, :mid_turn}
      :ok = FileStore.close(journal)
      assert dangling == last + 1

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued #{dangling} events"

      # State fresh: the count is back at zero.
      assert {:ok, "count: 0"} = call("agent_ask", %{"id" => id, "message" => "get"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      records = id |> read_journal!() |> Map.fetch!("records")

      # Offsets continue, without a gap or a repeat.
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..length(records))
      assert Enum.take(records, length(before)) == before

      # The marker, then the seal of the dangling turn.
      assert [marker, seal | _later] = Enum.drop(records, dangling)
      assert %{"type" => "agent_started", "payload" => %{"prior_offset" => ^dangling}} = marker

      assert %{
               "type" => "turn_canceled",
               "turn_id" => "turn-left-open",
               "payload" => %{"reason" => "agent_restarted"}
             } = seal

      # No turn is open any more: the checkpoint rule itself says so.
      {:ok, journal} = FileStore.open(id, base_dir: Path.dirname(journal_dir(root, id)))
      assert {:ok, _offset} = Checkpoint.write(journal, nil)
      :ok = FileStore.close(journal)
    end

    test "an agent whose tree was ended elsewhere can be spawned again", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      [{old_tree, _}] = Registry.lookup(Raxol.Agent.Registry, {:session_supervisor, id})
      :ok = Session.Supervisor.stop_session(id)

      assert {:ok, status} = call("agent_status", %{"id" => id})
      assert %{"state" => "stopped"} = Jason.decode!(status)

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued"

      # Word of the old tree's end arriving late changes nothing.
      send(McpTools, {:DOWN, make_ref(), :process, old_tree, :shutdown})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})
    end
  end
end

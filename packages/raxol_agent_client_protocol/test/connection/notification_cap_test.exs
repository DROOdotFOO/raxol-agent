# The notification handler cap and its backlog, asserted from the wire.
defmodule Raxol.AgentClientProtocol.Connection.NotificationCapTest.BacklogClient do
  @moduledoc false
  use Raxol.AgentClientProtocol.Client

  # Every update reports to the test process. A "hold" mode update then waits
  # for `:go`, so the test decides when it finishes; any other update works
  # for 10ms, long enough that the next queued frame is always handled while it
  # still runs.
  @impl true
  def session_update(note, ctx) do
    send(ctx.handler_state, {:backlog_update, note, self()})
    {:current_mode_update, %{current_mode_id: mode}} = note.update

    if String.starts_with?(mode, "hold") do
      receive do
        :go -> :ok
      after
        1_000 -> :ok
      end
    else
      Process.sleep(10)
    end

    :ok
  end
end

defmodule Raxol.AgentClientProtocol.Connection.NotificationCapTest do
  # Not async: telemetry handlers are global, and other files' Connections
  # emit the same events.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Connection.NotificationCapTest.BacklogClient
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  @shed [:raxol, :acp, :notification_shed]
  @queued [:raxol, :acp, :notification_queued]

  setup do
    id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach_many(
      id,
      [@shed, @queued],
      fn event, measurements, _meta, _ -> send(test_pid, {:telemetry, event, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  defp start_conn(opts) do
    task_sup = start_supervised!({Task.Supervisor, []}, id: {:task_sup, make_ref()})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(%{
        id: {Connection, make_ref()},
        start:
          {Connection, :start_link,
           [
             [
               role: :client,
               transport: {Paired, conn_handle},
               handler: BacklogClient,
               handler_arg: self(),
               task_sup: task_sup
             ] ++ opts
           ]},
        restart: :temporary
      })

    init =
      Task.async(fn ->
        Connection.request(conn, "initialize", %{"protocolVersion" => 1}, 2000)
      end)

    frame = ScriptedPeer.recv(peer)
    ScriptedPeer.send_result(peer, frame["id"], %{"protocolVersion" => 1})
    {:ok, _} = Task.await(init)

    send_update = fn mode ->
      ScriptedPeer.send_notification(peer, "session/update", %{
        "sessionId" => "s1",
        "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode}
      })
    end

    {conn, send_update}
  end

  defp mode(note) do
    {:current_mode_update, %{current_mode_id: mode}} = note.update
    mode
  end

  defp mailbox_len(pid) do
    {:message_queue_len, n} = Process.info(pid, :message_queue_len)
    n
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        flunk("condition not met within the wait budget")

      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end

  test "beyond the cap notifications wait in order; beyond the backlog they are dropped" do
    {conn, send_update} = start_conn(max_notification_tasks: 2, max_queued_notifications: 1)

    for m <- ["hold-1", "hold-2", "hold-3", "hold-4"], do: send_update.(m)

    # Two handlers run, the third notification waits and the fourth is shed.
    assert_receive {:backlog_update, n1, t1}
    assert_receive {:backlog_update, n2, t2}
    assert Enum.sort([mode(n1), mode(n2)]) == ["hold-1", "hold-2"]
    assert_receive {:telemetry, @queued, %{queued: 1}}
    assert_receive {:telemetry, @shed, _}
    refute_receive {:backlog_update, _, _}, 100

    # A finished handler's slot goes to the waiting notification.
    send(t1, :go)
    assert_receive {:backlog_update, n3, t3}
    assert mode(n3) == "hold-3"
    refute_receive {:backlog_update, _, _}, 100

    for t <- [t2, t3], do: send(t, :go)
    wait_until(fn -> :sys.get_state(conn).notif_pool.running == 0 end)
  end

  test "the backlog's size bound drops a notification its count bound would admit" do
    {_conn, send_update} =
      start_conn(
        max_notification_tasks: 1,
        max_queued_notifications: 100,
        max_queued_notification_bytes: 700
      )

    send_update.("hold-1")
    assert_receive {:backlog_update, _, t1}

    # Each waiting update is about 290 bytes, so the third does not fit.
    for m <- ["hold-2", "hold-3", "hold-4"], do: send_update.(m)
    assert_receive {:telemetry, @queued, %{queued: 1}}
    assert_receive {:telemetry, @queued, %{queued: 2}}
    assert_receive {:telemetry, @shed, _}

    send(t1, :go)
    assert_receive {:backlog_update, n2, t2}
    assert mode(n2) == "hold-2"
    send(t2, :go)
    assert_receive {:backlog_update, n3, t3}
    assert mode(n3) == "hold-3"
    send(t3, :go)
    refute_receive {:backlog_update, _, _}, 100
  end

  # Eight frames queue behind the parked handlers' results. Each queued
  # handler works for 10ms, so every frame after the first two arrives while
  # the earlier ones still run: without the backlog they are shed. Before the
  # backlog existed this failed 10 runs of 10; three rounds repeat the burst.
  test "a backlog of notifications waits for the cap instead of being shed" do
    cap = 2
    {conn, send_update} = start_conn(max_notification_tasks: cap)

    for round <- 1..3 do
      for i <- 1..cap, do: send_update.("hold-#{round}-#{i}")

      parked =
        for _ <- 1..cap do
          assert_receive {:backlog_update, _, pid}
          pid
        end

      # Eight frames queue, then the parked handlers finish: their results
      # land in the Connection's mailbox behind the frames.
      :sys.suspend(conn)
      for i <- 1..8, do: send_update.("m-#{round}-#{i}")
      wait_until(fn -> mailbox_len(conn) >= 8 end)
      for pid <- parked, do: send(pid, :go)
      wait_until(fn -> Enum.all?(parked, &(not Process.alive?(&1))) end)
      :sys.resume(conn)

      # They start in order but run concurrently, so only the set is checked.
      modes =
        for _ <- 1..8 do
          assert_receive {:backlog_update, note, _pid}, 1_000
          mode(note)
        end

      assert Enum.sort(modes) == Enum.sort(for i <- 1..8, do: "m-#{round}-#{i}")

      refute_received {:telemetry, @shed, _}
      wait_until(fn -> map_size(:sys.get_state(conn).task_index) == 0 end)
    end
  end

  test "queued notifications are reported dropped when the connection closes" do
    {conn, send_update} = start_conn(max_notification_tasks: 1)

    send_update.("hold-1")
    assert_receive {:backlog_update, _, _t1}
    send_update.("hold-2")
    assert_receive {:telemetry, @queued, %{queued: 1}}

    :ok = Connection.close(conn)
    assert_receive {:telemetry, @shed, _}
  end

  for key <- [:max_notification_tasks, :max_queued_notifications, :max_queued_notification_bytes] do
    test "a non-positive or non-integer #{inspect(key)} refuses to start" do
      Process.flag(:trap_exit, true)

      for bad <- [0, -1, 1.5, :infinity] do
        {conn_handle, _peer} = ScriptedPeer.new()

        assert {:error, {:invalid_option, unquote(key), ^bad}} =
                 Connection.start_link(
                   [
                     role: :client,
                     transport: {Paired, conn_handle},
                     handler: BacklogClient,
                     handler_arg: self(),
                     task_sup: self()
                   ] ++ [{unquote(key), bad}]
                 )
      end
    end
  end
end

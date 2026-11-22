# Connection bounds: inbound flood shedding, handler and adopter result
# validation, the close drain bound and the cancel reply timeout.
defmodule Raxol.AgentClientProtocol.ConnectionLimitsTest do
  # async: false -- several tests use `:erlang.system_info(:atom_count)`
  # (node-wide) and the package-level named `SessionRegistry` singleton
  # (Inv-20/21, session/cancel routing); both need exclusive scheduling,
  # matching the precedent in `method_table_test.exs`/`session_test.exs`.
  use Raxol.AgentClientProtocol.Test.ConnectionCase, async: false

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse

  # ===========================================================================
  # Inbound flood shedding (unbounded concurrent inbound dispatch — DoS).
  #
  # A hostile/slow peer that streams more concurrent inbound REQUESTS than the
  # Connection can retire grows `pending_in`/`reply_refs`/`task_index` (and the
  # dispatch task set) without bound. The Connection must SHED the overflow —
  # answer `-32603` (server busy) and dispatch NOTHING — never block the link
  # and never let those maps grow past the cap.
  # ===========================================================================

  defp start_agent_conn_capped(max_inbound) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        connection_child_spec(
          role: :agent,
          transport: {Paired, conn_handle},
          handler: ScriptAgent,
          handler_arg: self(),
          task_sup: task_sup,
          max_inbound: max_inbound
        )
      )

    %{conn: conn, peer: peer, task_sup: task_sup}
  end

  describe "inbound flood shedding (bounded pending_in)" do
    test "concurrent inbound requests over the cap are shed -32603; pending_in stays bounded" do
      cap = 4
      %{conn: conn, peer: peer} = start_agent_conn_capped(cap)
      complete_handshake(peer)

      # Park `cap` inbound requests in the handler: each new_session dispatch
      # blocks (we never hand it the run closure), so its pending_in entry
      # persists. After `cap` invokes land, pending_in is saturated.
      Enum.each(1..cap, fn i ->
        ScriptedPeer.send_request(peer, 100 + i, "session/new", new_session_params())
      end)

      for _ <- 1..cap do
        assert_receive {:handler_invoke, :new_session, _p, _c, _task_pid, _ref}, 500
      end

      wait_until(fn -> map_size(:sys.get_state(conn).pending_in) == cap end)

      # Two MORE concurrent requests: the cap is saturated, so they must be shed
      # with -32603 and NOT dispatched (no further handler_invoke), and
      # pending_in must NOT grow past the cap.
      ScriptedPeer.send_request(peer, 900, "session/new", new_session_params())
      ScriptedPeer.send_request(peer, 901, "session/new", new_session_params())

      shed1 = ScriptedPeer.recv(peer)
      shed2 = ScriptedPeer.recv(peer)

      assert shed1["id"] == 900
      assert shed1["error"]["code"] == -32_603
      assert shed2["id"] == 901
      assert shed2["error"]["code"] == -32_603

      refute_receive {:handler_invoke, :new_session, _p, _c, _tp, _r}, 100

      assert map_size(:sys.get_state(conn).pending_in) == cap
      assert map_size(:sys.get_state(conn).reply_refs) == cap
      assert Process.alive?(conn)
    end

    test "a non-positive-integer :max_inbound refuses to start (the guard fails closed)" do
      Process.flag(:trap_exit, true)
      {conn_handle, _peer} = ScriptedPeer.new()

      for bad <- [:infinity, nil, 0, -1, 1.5] do
        assert {:error, {:invalid_option, :max_inbound, ^bad}} =
                 Connection.start_link(
                   role: :agent,
                   transport: {Paired, conn_handle},
                   handler: ScriptAgent,
                   handler_arg: self(),
                   task_sup: self(),
                   max_inbound: bad
                 )
      end
    end
  end

  describe "handler and adopter result validation" do
    test "an extension request may answer with a plain map" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 7, "_vendor/echo", %{"x" => 1})

      handle_next_invoke(:ext_request, fn {"_vendor/echo", _params}, _ctx ->
        {:ok, %{"echo" => true}}
      end)

      assert %{"id" => 7, "result" => %{"echo" => true}} = ScriptedPeer.recv(peer)
    end

    test "an extension result Jason cannot encode is -32603, not a crash" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      for {id, bad} <- [{70, %{{1, 2} => 1}}, {71, %{"a" => [1 | 2]}}] do
        ScriptedPeer.send_request(peer, id, "_vendor/echo", %{})
        handle_next_invoke(:ext_request, fn _wire_params, _ctx -> {:ok, bad} end)
        assert %{"id" => ^id, "error" => %{"code" => -32_603}} = ScriptedPeer.recv(peer)
      end

      assert Process.alive?(conn)
    end

    test "a table method answering with a plain map is -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 8, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> {:ok, %{"sessionId" => "s"}} end)

      assert %{"id" => 8, "error" => %{"code" => -32_603}} = ScriptedPeer.recv(peer)
    end

    test "a cancel before delegation answers -32800 once and refuses the delegation" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 20, "session/prompt", prompt_params("s1"))

      %{ctx: ctx} =
        handle_next_invoke(:prompt, fn _req, _ctx ->
          send(test_pid, :blocked)
          receive do: (:never -> :ok)
        end)

      assert_receive :blocked
      ScriptedPeer.send_cancel_request(peer, 20)

      wait_until(fn ->
        case :sys.get_state(conn).pending_in do
          %{20 => %{cancelled?: false}} -> false
          _ -> true
        end
      end)

      assert %{"id" => 20, "error" => %{"code" => -32_800}} = ScriptedPeer.recv(peer)
      assert {:error, :unknown_ref} = Connection.delegate_reply(conn, ctx.reply_ref, self())
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "a cancel between delegation and :deferred: the adopter's reply is the one frame" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 22, "session/prompt", prompt_params("s1"))

      %{ctx: ctx, task_pid: task} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated)
          receive do: (:go -> :deferred)
        end)

      assert_receive :delegated
      ScriptedPeer.send_cancel_request(peer, 22)
      assert_receive {:acp_reply_cancelled, _ref}
      send(task, :go)

      wait_until(fn -> match?(%{22 => %{task_pid: nil}}, :sys.get_state(conn).pending_in) end)
      :ok = Connection.reply(conn, ctx.reply_ref, {:ok, PromptResponse.new(:cancelled)})
      assert %{"id" => 22, "result" => %{"stopReason" => "cancelled"}} = ScriptedPeer.recv(peer)
      ScriptedPeer.assert_no_frame(peer, 150)
      assert :sys.get_state(conn).pending_in == %{}
    end

    test "a stale handler result does not touch a newer request that reused its id" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 30, "session/prompt", prompt_params("s1"))

      %{ctx: ctx, task_pid: old_task} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated)
          receive do: (:go -> :deferred)
        end)

      assert_receive :delegated
      :ok = Connection.reply(conn, ctx.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      assert %{"id" => 30, "result" => _} = ScriptedPeer.recv(peer)

      ScriptedPeer.send_request(peer, 30, "session/new", new_session_params())

      %{task_pid: new_task} =
        handle_next_invoke(:new_session, fn _req, _ctx ->
          receive do: (:go ->
                         {:ok,
                          Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse.new("s2")})
        end)

      send(old_task, :go)
      ScriptedPeer.assert_no_frame(peer, 150)
      send(new_task, :go)
      assert %{"id" => 30, "result" => %{"sessionId" => "s2"}} = ScriptedPeer.recv(peer)
    end

    test "a handler crash after delegating leaves the reply to the adopter" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 21, "session/prompt", prompt_params("s1"))

      %{ctx: ctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          exit(:boom)
        end)

      ScriptedPeer.assert_no_frame(peer, 150)
      :ok = Connection.reply(conn, ctx.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      assert %{"id" => 21, "result" => %{"stopReason" => "end_turn"}} = ScriptedPeer.recv(peer)
    end

    test "a peer cannot forge log lines through the method name" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ScriptedPeer.send_raw(peer, %{
            "jsonrpc" => "2.0",
            "id" => nil,
            "method" => "session/new\n[error] FORGED"
          })

          _ = ScriptedPeer.recv(peer)
        end)

      assert log =~ ~S(session/new\n[error] FORGED)
      refute log =~ "\n[error] FORGED"
    end

    test "a malformed delegated reply is answered -32603 and the Connection survives" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 9, "session/prompt", prompt_params("s1"))

      %{ctx: ctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      assert :ok = Connection.reply(conn, ctx.reply_ref, {:error, :not_an_error_struct})

      assert %{"id" => 9, "error" => %{"code" => -32_603}} = ScriptedPeer.recv(peer)
      assert Process.alive?(conn)
    end
  end

  describe "close drain bound" do
    defp start_drain_conn(close_drain_ms) do
      task_sup = start_supervised!({Task.Supervisor, []}, id: {:drain_sup, make_ref()})
      {conn_handle, peer} = ScriptedPeer.new()

      conn =
        start_supervised!(
          connection_child_spec(
            role: :agent,
            transport: {Paired, conn_handle},
            handler: ScriptAgent,
            handler_arg: self(),
            task_sup: task_sup,
            close_drain_ms: close_drain_ms
          )
        )

      %{conn: conn, peer: peer}
    end

    test "outbound requests fail at once when the peer closes, while inbound drains" do
      %{conn: conn, peer: peer} = start_drain_conn(:infinity)
      complete_handshake(peer)
      ScriptedPeer.send_request(peer, 89, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> receive do: (:never -> :ok) end)

      :ok =
        Connection.async_request(
          conn,
          "session/request_permission",
          %{"sessionId" => "s"},
          self(),
          :perm,
          60_000
        )

      _ = ScriptedPeer.recv(peer)
      send(conn, {:acp_transport, :sys.get_state(conn).transport_ref, {:closed, :eof}})

      assert_receive {:acp_result, :perm, {:error, :connection_closed}}, 500
      assert %{draining?: true, pending_out: out} = :sys.get_state(conn)
      assert out == %{}
    end

    test "the peer's answer to a request this side cancelled is dropped quietly" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :telemetry.attach(
        "late-resp",
        [:raxol, :acp, :late_response],
        &__MODULE__.forward_telemetry/4,
        self()
      )

      on_exit(fn -> :telemetry.detach("late-resp") end)

      :ok =
        Connection.async_request(
          conn,
          "session/request_permission",
          %{"sessionId" => "s"},
          self(),
          :t,
          60_000
        )

      %{"id" => id} = ScriptedPeer.recv(peer)
      :ok = Connection.cancel_request(conn, :t)
      assert %{"method" => "$/cancel_request"} = ScriptedPeer.recv(peer)

      ScriptedPeer.send_error(peer, id, %{"code" => -32_800, "message" => "Request cancelled"})
      _ = :sys.get_state(conn)
      refute_receive {:telemetry, [:raxol, :acp, :late_response], _}, 100
      assert :sys.get_state(conn).abandoned_out == %{}
    end

    test "while draining, new requests are refused but notifications still go out" do
      %{conn: conn, peer: peer} = start_drain_conn(:infinity)
      complete_handshake(peer)
      ScriptedPeer.send_request(peer, 90, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> receive do: (:never -> :ok) end)

      send(conn, {:acp_transport, :sys.get_state(conn).transport_ref, {:closed, :eof}})

      assert {:error, :connection_closed} =
               Connection.async_request(
                 conn,
                 "session/request_permission",
                 %{"sessionId" => "s"},
                 self(),
                 :p,
                 60_000
               )

      :ok = Connection.notify(conn, "session/update", session_update_params("s1"))
      assert %{"method" => "session/update"} = ScriptedPeer.recv(peer)
    end

    test "a peer that is gone entirely is not drained" do
      %{conn: conn, peer: peer} = start_drain_conn(:infinity)
      complete_handshake(peer)
      ScriptedPeer.send_request(peer, 91, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> receive do: (:never -> :ok) end)

      cmon = Process.monitor(conn)

      send(
        conn,
        {:acp_transport, :sys.get_state(conn).transport_ref, {:closed, {:exit_status, 1}}}
      )

      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
    end

    test ":close_drain_ms bounds how long a closed connection waits" do
      %{conn: conn, peer: peer} = start_drain_conn(100)
      complete_handshake(peer)
      ScriptedPeer.send_request(peer, 88, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> receive do: (:never -> :ok) end)

      cmon = Process.monitor(conn)
      send(conn, {:acp_transport, :sys.get_state(conn).transport_ref, {:closed, :eof}})
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 1_000
    end

    test "an invalid :close_drain_ms refuses to start" do
      Process.flag(:trap_exit, true)
      {conn_handle, _peer} = ScriptedPeer.new()

      for bad <- [0, nil, "5s"] do
        assert {:error, {:invalid_option, :close_drain_ms, ^bad}} =
                 Connection.start_link(
                   role: :agent,
                   transport: {Paired, conn_handle},
                   handler: ScriptAgent,
                   handler_arg: self(),
                   task_sup: self(),
                   close_drain_ms: bad
                 )
      end
    end
  end

  describe "cancel reply timeout" do
    test "an adopter that never replies after a cancel: -32800 after the timeout, slot freed, late reply quiet" do
      test_pid = self()
      task_sup = start_supervised!({Task.Supervisor, []}, id: :cancel_timeout_sup)
      {conn_handle, peer} = ScriptedPeer.new()

      conn =
        start_supervised!(
          connection_child_spec(
            role: :agent,
            transport: {Paired, conn_handle},
            handler: ScriptAgent,
            handler_arg: self(),
            task_sup: task_sup,
            cancel_reply_timeout_ms: 100
          )
        )

      complete_handshake(peer)
      ScriptedPeer.send_request(peer, 60, "session/prompt", prompt_params("s1"))

      %{ctx: ctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated)
          :deferred
        end)

      assert_receive :delegated
      ScriptedPeer.send_cancel_request(peer, 60)
      assert_receive {:acp_reply_cancelled, _ref}

      assert %{"id" => 60, "error" => %{"code" => -32_800}} = ScriptedPeer.recv(peer)
      assert :sys.get_state(conn).pending_in == %{}

      assert map_size(:sys.get_state(conn).timed_out_adopters) == 1

      # A late reply is a quiet no-op: no dup_reply, no second frame.
      :telemetry.attach(
        "late-reply",
        [:raxol, :acp, :dup_reply],
        &__MODULE__.forward_telemetry/4,
        self()
      )

      on_exit(fn -> :telemetry.detach("late-reply") end)

      :ok = Connection.reply(conn, ctx.reply_ref, {:ok, PromptResponse.new(:cancelled)})
      ScriptedPeer.assert_no_frame(peer, 150)
      refute_receive {:telemetry, [:raxol, :acp, :dup_reply], _}
      assert :sys.get_state(conn).timed_out_adopters == %{}
    end

    test "a repeated cancel for a delegated id is a no-op" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      ScriptedPeer.send_request(peer, 62, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn _req, ctx ->
        :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
        send(test_pid, :delegated)
        :deferred
      end)

      assert_receive :delegated
      for _ <- 1..5, do: ScriptedPeer.send_cancel_request(peer, 62)

      assert_receive {:acp_reply_cancelled, _ref}
      refute_receive {:acp_reply_cancelled, _ref}, 150
      assert %{62 => %{cancelled?: true}} = :sys.get_state(conn).pending_in
    end

    test "the tombstone is dropped when the silent adopter exits" do
      test_pid = self()
      task_sup = start_supervised!({Task.Supervisor, []}, id: :cancel_timeout_sup2)
      {conn_handle, peer} = ScriptedPeer.new()

      conn =
        start_supervised!(
          connection_child_spec(
            role: :agent,
            transport: {Paired, conn_handle},
            handler: ScriptAgent,
            handler_arg: self(),
            task_sup: task_sup,
            cancel_reply_timeout_ms: 50
          )
        )

      complete_handshake(peer)
      adopter = spawn(fn -> receive do: (:stop -> :ok) end)
      ScriptedPeer.send_request(peer, 61, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn _req, ctx ->
        :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, adopter)
        send(test_pid, :delegated)
        :deferred
      end)

      assert_receive :delegated
      ScriptedPeer.send_cancel_request(peer, 61)
      assert %{"id" => 61, "error" => %{"code" => -32_800}} = ScriptedPeer.recv(peer)

      send(adopter, :stop)

      wait_until(fn ->
        match?(
          %{timed_out_adopters: e, reply_refs: r} when e == %{} and r == %{},
          :sys.get_state(conn)
        )
      end)

      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "an invalid :cancel_reply_timeout_ms refuses to start" do
      Process.flag(:trap_exit, true)
      {conn_handle, _peer} = ScriptedPeer.new()

      for bad <- [-1, 0, nil, "5s"] do
        assert {:error, {:invalid_option, :cancel_reply_timeout_ms, ^bad}} =
                 Connection.start_link(
                   role: :agent,
                   transport: {Paired, conn_handle},
                   handler: ScriptAgent,
                   handler_arg: self(),
                   task_sup: self(),
                   cancel_reply_timeout_ms: bad
                 )
      end
    end

    test ":infinity is accepted for both timeout options" do
      {conn_handle, _peer} = ScriptedPeer.new()

      assert {:ok, conn} =
               Connection.start_link(
                 role: :agent,
                 transport: {Paired, conn_handle},
                 handler: ScriptAgent,
                 handler_arg: self(),
                 task_sup: self(),
                 close_drain_ms: :infinity,
                 cancel_reply_timeout_ms: :infinity
               )

      assert %{close_drain_ms: :infinity, cancel_reply_timeout_ms: :infinity} =
               :sys.get_state(conn)

      :ok = Connection.close(conn)
    end
  end

  @doc false
  def forward_telemetry(event, _measurements, metadata, pid),
    do: send(pid, {:telemetry, event, metadata})
end

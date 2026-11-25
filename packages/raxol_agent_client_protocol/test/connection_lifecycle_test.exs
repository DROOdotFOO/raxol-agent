# Connection invariants Inv-12..Inv-21 (INVARIANTS.md): transport-down
# cleanup, duplicate ids, malformed frames, task reaping, delegated replies
# and session/cancel delivery, asserted from the wire.
defmodule Raxol.AgentClientProtocol.ConnectionLifecycleTest do
  # async: false -- several tests use `:erlang.system_info(:atom_count)`
  # (node-wide) and the package-level named `SessionRegistry` singleton
  # (Inv-20/21, session/cancel routing); both need exclusive scheduling,
  # matching the precedent in `method_table_test.exs`/`session_test.exs`.
  use Raxol.AgentClientProtocol.Test.ConnectionCase, async: false

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest

  describe "invariants" do
    test "Inv-12: transport down delivers total cleanup for pending_in (undelegated killed, delegated silent)" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, "u", "session/new", new_session_params())

      %{task_pid: undelegated} =
        handle_next_invoke(:new_session, fn _r, _c -> Process.sleep(:infinity) end)

      uref = Process.monitor(undelegated)

      ScriptedPeer.send_request(peer, "d", "session/prompt", prompt_params("s1"))

      %{ctx: dctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      _ = dctx

      %{transport_ref: carrier} = :sys.get_state(conn)
      cmon = Process.monitor(conn)
      Process.unlink(carrier)
      Process.exit(carrier, :kill)

      assert_receive {:DOWN, ^uref, :process, ^undelegated, _}, 500
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "Inv-13: closed-delivery + monitor DOWN is idempotent (single cleanup, single stop)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv13,
          5000
        )

      _frame = ScriptedPeer.recv(peer)

      %{transport_ref: ref, transport_monitor: mon} = :sys.get_state(conn)
      cmon = Process.monitor(conn)

      # simulate both convergence-point signals landing (closed delivery,
      # then the monitor DOWN) -- §3 says double delivery must be safe.
      send(conn, {:acp_transport, ref, {:closed, :simulated}})
      send(conn, {:DOWN, mon, :process, self(), :simulated})

      assert_receive {:acp_result, :inv13, {:error, :connection_closed}}, 500
      # exactly one delivery -- a second cleanup pass would not re-send it,
      # but there is nothing left to observe a double-send with here beyond
      # the single clean stop below.
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
    end

    test "Inv-14: duplicate in-flight inbound id produces zero additional frames" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 42, "session/new", new_session_params("/first"))

      # the fun blocks on its own `receive` so the original dispatch stays
      # genuinely in flight until we `:go` it below -- `handle_next_invoke`
      # only hands the closure to the task, it does not wait for the
      # closure to finish running.
      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn req, _ctx ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{
                 session_id: req.cwd
               }}
          end
        end)

      # duplicate id while the original is still in flight -- must be
      # dropped, no second dispatch/frame
      ScriptedPeer.send_request(peer, 42, "session/new", new_session_params("/second"))
      refute_receive {:handler_invoke, :new_session, %{cwd: "/second"}, _, _, _}, 200

      send(task_pid, :go)
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 42
      assert frame["result"]["sessionId"] == "/first"
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "a closed read side lets an in-flight inbound request still answer" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 77, "session/new", new_session_params("/held"))

      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn req, _ctx ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{
                 session_id: req.cwd
               }}
          end
        end)

      %{transport_ref: ref} = :sys.get_state(conn)
      cmon = Process.monitor(conn)

      # stdin ends while the handler is still running. A peer that pipes its
      # requests and closes stdin must still get the reply the agent is
      # already producing.
      send(conn, {:acp_transport, ref, {:closed, :eof}})
      refute_receive {:DOWN, ^cmon, :process, ^conn, _reason}, 200

      send(task_pid, :go)
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 77
      assert frame["result"]["sessionId"] == "/held"

      # Nothing left in flight: the Connection stops right away.
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
    end

    test "a closed read side with nothing in flight still stops at once" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      %{transport_ref: ref} = :sys.get_state(conn)
      cmon = Process.monitor(conn)

      send(conn, {:acp_transport, ref, {:closed, :eof}})
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
    end

    test "Inv-15: malformed frames never terminate the connection or disturb an in-flight request" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 200, "session/new", new_session_params())

      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn _r, _c ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
          end
        end)

      # interleave garbage while the real request is still pending
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0"})
      ScriptedPeer.send_raw_unchecked(peer, [%{"jsonrpc" => "2.0"}])
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0", "id" => "garbage-id"})

      g1 = ScriptedPeer.recv(peer)
      assert g1["id"] == nil
      g2 = ScriptedPeer.recv(peer)
      assert g2["id"] == nil
      g3 = ScriptedPeer.recv(peer)
      assert g3["id"] == "garbage-id"

      send(task_pid, :go)
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 200
      assert frame["result"]["sessionId"] == "s1"
      assert Process.alive?(conn)
    end

    test "Inv-16: handler crash detail never reaches the wire" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      marker = "SECRET-#{System.unique_integer([:positive])}-DO-NOT-LEAK"
      ScriptedPeer.send_request(peer, 9, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> raise marker end)

      frame = ScriptedPeer.recv(peer)
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
      refute String.contains?(inspect(frame), marker)
    end

    test "Inv-17: every task ref / reply_ref is tracked and reaped at quiescence" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # a plain request/response round trip
      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      _ = ScriptedPeer.recv(peer)

      # a delegated reply, resolved
      ScriptedPeer.send_request(peer, 2, "session/prompt", prompt_params("s1"))

      %{ctx: ctx2} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      :ok = Connection.reply(conn, ctx2.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      _ = ScriptedPeer.recv(peer)

      wait_until(fn ->
        st = :sys.get_state(conn)

        map_size(st.task_index) == 0 and map_size(st.reply_refs) == 0 and
          map_size(st.pending_in) == 0 and map_size(st.reply_refs) == map_size(st.pending_in)
      end)
    end

    test "Inv-18: ids are opaque after minting -- a pre-namespaced string id from a fan-out proxy round-trips" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, "c1|5", "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:ok, %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
      end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == "c1|5"
    end

    # Inv-19 exists to drive a second reply on an already-consumed obligation,
    # so the suppression telemetry is the observable under test. Declared, not
    # muted: the tag asserts it fires.
    @tag expect_invariant: [[:raxol, :acp, :dup_reply]]
    test "Inv-19: delegated-reply idempotence across reply/second-reply/adopter-DOWN/cancel interleavings" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # reply then a second reply -> second is a suppressed no-op, still :ok
      ScriptedPeer.send_request(peer, 1, "session/prompt", prompt_params("s1"))

      %{ctx: c1} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      assert :ok = Connection.reply(conn, c1.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      f1 = ScriptedPeer.recv(peer)
      assert f1["id"] == 1
      assert :ok = Connection.reply(conn, c1.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      ScriptedPeer.assert_no_frame(peer, 150)

      # cancel then reply -> the adopter's reply is the one frame
      ScriptedPeer.send_request(peer, 2, "session/prompt", prompt_params("s1"))

      %{ctx: c2} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated_2)
          :deferred
        end)

      # wait for delegate_reply's own GenServer.call to have landed at the
      # Connection before racing the (multi-hop) cancel notification in --
      # see the identical note on Inv-4's delegated sub-case.
      assert_receive :delegated_2, 500
      ScriptedPeer.send_cancel_request(peer, 2)
      assert_receive {:acp_reply_cancelled, ref2} when ref2 == c2.reply_ref, 500
      assert :ok = Connection.reply(conn, c2.reply_ref, {:ok, PromptResponse.new(:cancelled)})
      assert %{"id" => 2, "result" => _} = ScriptedPeer.recv(peer)
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "Inv-20: rx_seq is monotone across an interleaved inbound burst" do
      start_supervised!(Session.Supervisor.registry_child_spec())
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      session_id = "seq-sess"
      {:ok, _owner} = Registry.register(Session.registry(), {conn, session_id}, nil)

      ScriptedPeer.send_request(peer, "s1", "session/new", new_session_params())

      %{ctx: sctx1} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      ScriptedPeer.send_session_cancel(peer, session_id)
      assert_receive {:"$gen_cast", {:acp_session_cancel, seq_cancel}}, 500

      ScriptedPeer.send_request(peer, "s2", "session/new", new_session_params())

      %{ctx: sctx2} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      assert sctx1.rx_seq < seq_cancel
      assert seq_cancel < sctx2.rx_seq
    end

    test "Inv-21: session/cancel delivery runs no user code and survives any handler crash" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      start_supervised!(Session.Supervisor.registry_child_spec())
      session_id = "surviving-sess"
      {:ok, _owner} = Registry.register(Session.registry(), {conn, session_id}, nil)

      # crash a handler first
      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> raise "handler is on fire" end)
      _ = ScriptedPeer.recv(peer)

      # session/cancel still reaches the registered session, no user code ran
      ScriptedPeer.send_session_cancel(peer, session_id)
      assert_receive {:"$gen_cast", {:acp_session_cancel, _rx_seq}}, 500
      refute_receive {:handler_invoke, _, _, _, _, _}, 150
    end
  end
end

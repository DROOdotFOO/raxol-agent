# Connection: the §8 sequence diagrams and invariants Inv-1..Inv-11
# (INVARIANTS.md), asserted from the wire. Inv-12..Inv-21 are in
# connection_lifecycle_test.exs; the fixtures in test/support/connection_case.ex.
defmodule Raxol.AgentClientProtocol.ConnectionTest do
  # async: false -- several tests use `:erlang.system_info(:atom_count)`
  # (node-wide) and the package-level named `SessionRegistry` singleton
  # (Inv-20/21, session/cancel routing); both need exclusive scheduling,
  # matching the precedent in `method_table_test.exs`/`session_test.exs`.
  use Raxol.AgentClientProtocol.Test.ConnectionCase, async: false

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest

  # §8. Sequence diagrams (six cited in the assignment; §8.7 is folded into
  # the "delegated reply" section below since it's a cancellation variant of
  # §8.3, not a distinct new mechanism).

  describe "§8 sequence diagrams" do
    test "§8.1 happy outbound (sync wrapper)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      caller =
        Task.async(fn ->
          Connection.request(conn, "fs/read_text_file", ReadTextFileRequest.new("s1", "/f"), 2000)
        end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "fs/read_text_file"
      assert is_integer(frame["id"])

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "hello"})

      assert {:ok, %{content: "hello"}} = Task.await(caller)
    end

    test "§8.2 outbound timeout + late reply (async form)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s1", "/f"),
          owner,
          :perm_tag,
          100
        )

      frame = ScriptedPeer.recv(peer)
      id = frame["id"]

      assert_receive {:acp_result, :perm_tag, {:error, :timeout}}, 500

      # a best-effort $/cancel_request notification for the timed-out id
      cancel_frame = ScriptedPeer.recv(peer)
      assert cancel_frame["method"] == "$/cancel_request"
      assert cancel_frame["params"]["requestId"] == id

      # late reply arrives after the timeout already fired -- dropped, no crash
      ScriptedPeer.send_result(peer, id, %{"content" => "too late"})
      refute_receive {:acp_result, :perm_tag, _}, 200
      assert Process.alive?(conn)
    end

    test "§8.3 inbound served via delegated reply (the prompt path)" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, "a-7", "session/prompt", prompt_params("s1"))

      %{ctx: ctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      :ok = Connection.notify(conn, "session/update", session_update_params("s1"))
      update_frame = ScriptedPeer.recv(peer)
      assert update_frame["method"] == "session/update"

      :ok = Connection.reply(conn, ctx.reply_ref, {:ok, PromptResponse.new(:end_turn)})

      resp = ScriptedPeer.recv(peer)
      assert resp["id"] == "a-7"
      assert resp["result"]["stopReason"] == "end_turn"
    end

    test "§8.4 inbound peer-cancelled mid-flight (undelegated request)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 9, "session/new", new_session_params())

      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn _req, _ctx -> Process.sleep(:infinity) end)

      task_ref = Process.monitor(task_pid)

      ScriptedPeer.send_cancel_request(peer, 9)

      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 500
      # The cancelled request is still answered: -32800, exactly once.
      assert %{"id" => 9, "error" => %{"code" => -32_800}} = ScriptedPeer.recv(peer)
      ScriptedPeer.assert_no_frame(peer, 200)
      assert Process.alive?(conn)
    end

    test "§8.5 nested bidirectional: handler calls outbound mid-inbound" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 3, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn req, ctx ->
        {:ok, %{content: _}} =
          Connection.request(
            ctx.conn,
            "fs/read_text_file",
            ReadTextFileRequest.new(req.session_id, "/needed"),
            2000
          )

        {:ok, PromptResponse.new(:end_turn)}
      end)

      nested = ScriptedPeer.recv(peer)
      assert nested["method"] == "fs/read_text_file"
      ScriptedPeer.send_result(peer, nested["id"], %{"content" => "contents"})

      resp = ScriptedPeer.recv(peer)
      assert resp["id"] == 3
      assert resp["result"]["stopReason"] == "end_turn"
    end

    test "§8.6 transport dies with pendings in both directions" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # pending_out #1: a parked `request/4` caller
      caller =
        Task.async(fn ->
          Connection.request(conn, "fs/read_text_file", ReadTextFileRequest.new("s", "/f"), 5000)
        end)

      out_frame1 = ScriptedPeer.recv(peer)
      assert out_frame1["method"] == "fs/read_text_file"

      # pending_out #2: an async_request owner
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/g"),
          test_pid,
          :t6,
          5000
        )

      out_frame2 = ScriptedPeer.recv(peer)
      assert out_frame2["method"] == "fs/read_text_file"

      # pending_in #1: undelegated task, still running
      ScriptedPeer.send_request(peer, "x", "session/new", new_session_params())

      %{task_pid: undelegated_task} =
        handle_next_invoke(:new_session, fn _req, _ctx -> Process.sleep(:infinity) end)

      undelegated_ref = Process.monitor(undelegated_task)

      # pending_in #2: delegated to test_pid ("y")
      ScriptedPeer.send_request(peer, "y", "session/prompt", prompt_params("s1"))

      %{ctx: ctx_y} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      _ctx_y = ctx_y

      # kill the transport carrier (deviation #4: transport_ref IS the carrier
      # pid). ScriptedPeer.new/0 creates both Paired handles via
      # GenServer.start_link/3 from THIS test process, so the carrier is
      # linked to us too -- unlink first or our own kill signal takes the
      # test process down with it.
      %{transport_ref: carrier} = :sys.get_state(conn)
      conn_mon = Process.monitor(conn)
      Process.unlink(carrier)
      Process.exit(carrier, :kill)

      assert {:error, :connection_closed} = Task.await(caller)
      assert_receive {:acp_result, :t6, {:error, :connection_closed}}, 500
      assert_receive {:DOWN, ^undelegated_ref, :process, ^undelegated_task, _}, 500
      assert_receive {:DOWN, ^conn_mon, :process, ^conn, :normal}, 500

      # no response was ever attempted for the delegated "y" id
      ScriptedPeer.assert_no_frame(peer, 100)
    end
  end

  # §10. Invariants Inv-1..Inv-21

  describe "invariants" do
    test "Inv-1: exactly one answer per accepted outbound submission; zero after cancel_request" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      # path A: correlated response -> exactly one delivery
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv1_a,
          2000
        )

      fa = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, fa["id"], %{"content" => "A"})
      assert_receive {:acp_result, :inv1_a, {:ok, %{content: "A"}}}
      refute_receive {:acp_result, :inv1_a, _}, 100

      # path B: internal timeout -> exactly one delivery
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/b"),
          owner,
          :inv1_b,
          80
        )

      _fb = ScriptedPeer.recv(peer)
      assert_receive {:acp_result, :inv1_b, {:error, :timeout}}, 500
      refute_receive {:acp_result, :inv1_b, _}, 100

      # path C: cancel_request -- consumed by the canceller -> ZERO deliveries, ever
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/c"),
          owner,
          :inv1_c,
          5000
        )

      fc = ScriptedPeer.recv(peer)
      :ok = Connection.cancel_request(conn, :inv1_c)
      refute_receive {:acp_result, :inv1_c, _}, 200
      # even a late wire reply for the cancelled id delivers nothing (row 15)
      ScriptedPeer.send_result(peer, fc["id"], %{"content" => "late"})
      refute_receive {:acp_result, :inv1_c, _}, 100
    end

    test "Inv-2: no stale pending_out/out_tags entries survive any exit path" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv2_a,
          2000
        )

      fa = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, fa["id"], %{"content" => "A"})
      assert_receive {:acp_result, :inv2_a, _}
      st = :sys.get_state(conn)
      refute Map.has_key?(st.pending_out, fa["id"])
      refute Map.has_key?(st.out_tags, {owner, :inv2_a})

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/b"),
          owner,
          :inv2_b,
          80
        )

      fb = ScriptedPeer.recv(peer)
      assert_receive {:acp_result, :inv2_b, {:error, :timeout}}, 500
      st2 = :sys.get_state(conn)
      refute Map.has_key?(st2.pending_out, fb["id"])
      refute Map.has_key?(st2.out_tags, {owner, :inv2_b})

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/c"),
          owner,
          :inv2_c,
          5000
        )

      fc = ScriptedPeer.recv(peer)
      :ok = Connection.cancel_request(conn, :inv2_c)
      st3 = :sys.get_state(conn)
      refute Map.has_key?(st3.pending_out, fc["id"])
      refute Map.has_key?(st3.out_tags, {owner, :inv2_c})
    end

    test "Inv-3: timeout answers AND deletes atomically; a late response after is a pure no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv3,
          80
        )

      frame = ScriptedPeer.recv(peer)
      assert_receive {:acp_result, :inv3, {:error, :timeout}}, 500

      # §2.3's best-effort $/cancel_request for the timed-out id -- drain it
      # so it doesn't get mistaken for the next round trip's frame below.
      cancel_notif = ScriptedPeer.recv(peer)
      assert cancel_notif["method"] == "$/cancel_request"

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "late"})
      refute_receive {:acp_result, :inv3, _}, 150
      assert Process.alive?(conn)

      # connection is still fully functional afterward
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/z"),
          owner,
          :inv3_after,
          2000
        )

      frame2 = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame2["id"], %{"content" => "ok"})
      assert_receive {:acp_result, :inv3_after, {:ok, %{content: "ok"}}}
    end

    test "IC-6 (Inv-4 alias): response-count invariant across normal/cancelled-undelegated/cancelled-delegated" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # normal -> exactly one response
      ScriptedPeer.send_request(peer, 100, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _req, _ctx ->
        {:ok, %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
      end)

      normal = ScriptedPeer.recv(peer)
      assert normal["id"] == 100
      assert normal["result"]["sessionId"] == "s1"

      # cancelled, undelegated -> exactly one -32800
      ScriptedPeer.send_request(peer, 101, "session/new", new_session_params())

      %{task_pid: t101} =
        handle_next_invoke(:new_session, fn _r, _c -> Process.sleep(:infinity) end)

      ref101 = Process.monitor(t101)
      ScriptedPeer.send_cancel_request(peer, 101)
      assert_receive {:DOWN, ^ref101, :process, ^t101, _reason}, 500
      assert %{"id" => 101, "error" => %{"code" => -32_800}} = ScriptedPeer.recv(peer)
      ScriptedPeer.assert_no_frame(peer, 150)

      # cancelled, delegated -> exactly one: the adopter's reply
      ScriptedPeer.send_request(peer, 102, "session/prompt", prompt_params("s1"))

      %{ctx: ctx102} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated_102)
          :deferred
        end)

      # delegate_reply/3 is itself a GenServer.call into the Connection, made
      # from the task; wait for it to have landed before racing the cancel
      # notification in from the peer side (several process hops away) --
      # otherwise the cancel can arrive while `adopter` is still nil and take
      # the undelegated kill branch instead of the delegated one this
      # sub-case is scripting.
      assert_receive :delegated_102, 500
      ScriptedPeer.send_cancel_request(peer, 102)
      assert_receive {:acp_reply_cancelled, reply_ref} when reply_ref == ctx102.reply_ref, 500
      :ok = Connection.reply(conn, ctx102.reply_ref, {:ok, PromptResponse.new(:cancelled)})
      assert %{"id" => 102, "result" => %{"stopReason" => "cancelled"}} = ScriptedPeer.recv(peer)
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "Inv-5: notifications never produce a wire frame, incl. decode failure and handler crash" do
      %{conn: conn, peer: peer} = start_client_conn()

      init_task =
        Task.async(fn ->
          Connection.request(conn, "initialize", %{"protocolVersion" => 1}, 2000)
        end)

      init_frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, init_frame["id"], %{"protocolVersion" => 1})
      {:ok, _} = Task.await(init_task)

      # handler crash on a notification -> log only, no frame, ever
      ScriptedPeer.send_notification(peer, "session/update", session_update_params("s1"))
      handle_next_invoke(:session_update, fn _note, _ctx -> raise "boom" end)
      ScriptedPeer.assert_no_frame(peer, 200)

      # decode failure -> dropped before the handler is ever invoked
      ScriptedPeer.send_notification(peer, "session/update", %{})
      refute_receive {:handler_invoke, :session_update, _, _, _, _}, 200
      ScriptedPeer.assert_no_frame(peer, 100)

      assert Process.alive?(conn)
    end

    test "Inv-6: response id echo is byte-exact across error classes, string and integer ids" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # -32601 method not found, string id
      ScriptedPeer.send_request(peer, "req-str", "not/a/real/method", %{})
      f1 = ScriptedPeer.recv(peer)
      assert f1["id"] == "req-str"
      assert f1["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()

      # -32602 invalid params, integer id
      ScriptedPeer.send_request(peer, 55, "session/new", %{})
      f2 = ScriptedPeer.recv(peer)
      assert f2["id"] == 55
      assert f2["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_params_code()

      # -32603 handler crash, string id
      ScriptedPeer.send_request(peer, "req-crash", "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> raise "boom" end)
      f3 = ScriptedPeer.recv(peer)
      assert f3["id"] == "req-crash"
      assert f3["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()

      # -32600 malformed frame carrying a wire-valid id, integer id
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0", "id" => 77})
      f4 = ScriptedPeer.recv(peer)
      assert f4["id"] == 77
      assert f4["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()
    end

    # The f4 case above is `%{"id" => 77}` -- neither
    # method nor result/error, so it exercises the benign catch-all arm of
    # `handle_message` (`true -> respond_malformed`), NOT `classify_response`'s
    # decode-failure arm. A frame that DOES classify as a response (has
    # "id" + "error"/"result") but fails `Response.from_json` -- e.g. an
    # error object whose "code" isn't an integer -- is a different, more
    # dangerous case: JSON-RPC 2.0 forbids ever answering a response, and
    # both roles mint `next_out_id` from 1, so an -32600 echo at that id
    # would cross-correlate into the PEER's own `pending_out` table and
    # deliver a bogus error to one of ITS unrelated in-flight requests.
    test "S1: a response-shaped malformed frame is dropped, never cross-correlated to pending_out" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          owner,
          :s1_inflight,
          150
        )

      frame = ScriptedPeer.recv(peer)
      id = frame["id"]

      # (a) malformed response-shaped frame reusing OUR OWN in-flight id.
      # Well inside the 150ms outbound timeout below -- proves the malformed
      # frame itself produced zero frames, not merely that the timeout
      # eventually overwrote the observation.
      ScriptedPeer.send_raw(peer, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => "oops"}
      })

      ScriptedPeer.assert_no_frame(peer, 100)

      # the real in-flight request is undisturbed by the malformed echo --
      # it resolves by its own timeout, never by a fabricated -32600.
      assert_receive {:acp_result, :s1_inflight, {:error, :timeout}}, 500

      # §2.3's best-effort $/cancel_request for the timed-out id -- drain it
      # so it isn't mistaken for a frame produced by case (b) below.
      cancel_notif = ScriptedPeer.recv(peer)
      assert cancel_notif["method"] == "$/cancel_request"

      # (b) malformed response-shaped frame for an id we never sent -- also
      # dropped silently.
      ScriptedPeer.send_raw(peer, %{
        "jsonrpc" => "2.0",
        "id" => 999_999,
        "error" => %{"code" => "oops"}
      })

      ScriptedPeer.assert_no_frame(peer, 150)
      assert Process.alive?(conn)
    end

    test "Inv-7: no atom is created from wire input (unknown methods, notifications, session ids)" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      random_methods = for _ <- 1..150, do: "unknown/" <> rand_hex()
      random_session_ids = for _ <- 1..150, do: rand_hex()

      before_count = :erlang.system_info(:atom_count)

      Enum.with_index(random_methods, 200)
      |> Enum.each(fn {method, id} ->
        ScriptedPeer.send_request(peer, id, method, %{})
        frame = ScriptedPeer.recv(peer)
        assert frame["id"] == id
        assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()
      end)

      Enum.each(random_methods, fn method ->
        ScriptedPeer.send_notification(peer, method, %{})
      end)

      Enum.each(random_session_ids, fn sid ->
        ScriptedPeer.send_session_cancel(peer, sid)
      end)

      # drain: prove the connection is still responsive (and therefore has
      # processed the notifications/cancels above) before the final count.
      ScriptedPeer.send_request(peer, 999_999, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      _drain = ScriptedPeer.recv(peer)

      after_count = :erlang.system_info(:atom_count)

      assert after_count - before_count < 50,
             "atom count grew by #{after_count - before_count} after 300 unknown wire strings"
    end

    test "Inv-8: a handler calling Connection.request/4 back into the same Connection completes promptly" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 3, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn req, ctx ->
        {:ok, %{content: _}} =
          Connection.request(
            ctx.conn,
            "fs/read_text_file",
            ReadTextFileRequest.new(req.session_id, "/f"),
            1000
          )

        {:ok, PromptResponse.new(:end_turn)}
      end)

      nested = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, nested["id"], %{"content" => "x"})

      # bounded wait proves the Connection never deadlocked on itself
      resp = ScriptedPeer.recv(peer, 1000)
      assert resp["id"] == 3
    end

    test "Inv-9: conn == self() raises ArgumentError on every public API function" do
      assert_raise ArgumentError, fn -> Connection.request(self(), "x", nil, 100) end

      assert_raise ArgumentError, fn ->
        Connection.async_request(self(), "x", nil, self(), :t, 100)
      end

      assert_raise ArgumentError, fn -> Connection.notify(self(), "x", nil) end
      assert_raise ArgumentError, fn -> Connection.cancel_request(self(), :t) end
      assert_raise ArgumentError, fn -> Connection.delegate_reply(self(), make_ref(), self()) end
      assert_raise ArgumentError, fn -> Connection.reply(self(), make_ref(), {:ok, %{}}) end
      assert_raise ArgumentError, fn -> Connection.close(self()) end
    end

    test "Inv-10: handshake gate, agent role (inbound -32600, outbound not_initialized)" do
      %{conn: conn, peer: peer} = start_agent_conn()

      # inbound request pre-handshake -> -32600, never dispatched
      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())
      refute_receive {:handler_invoke, :new_session, _, _, _, _}, 200
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 1
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()
      assert frame["error"]["data"]["reason"] == "initialize required"

      # outbound pre-handshake -> local error, no frame on the wire
      assert {:error, :not_initialized} =
               Connection.request(
                 conn,
                 "fs/read_text_file",
                 ReadTextFileRequest.new("s", "/f"),
                 200
               )

      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "Inv-10: handshake gate, client role (outbound gate then successful handshake)" do
      %{conn: conn, peer: peer} = start_client_conn()

      # outbound gate: any method but "initialize" is rejected pre-handshake
      assert {:error, :not_initialized} =
               Connection.request(conn, "session/new", %{"cwd" => "/tmp"}, 200)

      ScriptedPeer.assert_no_frame(peer, 100)

      init_task =
        Task.async(fn ->
          Connection.request(conn, "initialize", %{"protocolVersion" => 1}, 2000)
        end)

      init_frame = ScriptedPeer.recv(peer)
      assert init_frame["method"] == "initialize"
      ScriptedPeer.send_result(peer, init_frame["id"], %{"protocolVersion" => 1})
      assert {:ok, %InitializeResponse{protocol_version: 1}} = Task.await(init_task)
    end

    test "Inv-11: caps is written exactly once at handshake and never mutated after" do
      %{peer: peer} = start_agent_conn()
      ctx1 = complete_handshake(peer)

      # ctx1 is the dispatch ctx handed to the `initialize` handler itself --
      # built BEFORE that request's response is sent, so per §7.2 ("caps is
      # snapshotted in the same step" as the response) it can only be nil at
      # that point; it is not yet the negotiated snapshot.
      assert ctx1.caps == nil

      ScriptedPeer.send_request(peer, 2, "session/new", new_session_params())

      %{ctx: ctx2} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      refute ctx2.caps == nil

      # second initialize -> rejected, connection stays up, caps untouched,
      # and (per §7.2's "never dispatched" wording for the analogous
      # pre-handshake gate) the handler is not re-invoked for it either.
      ScriptedPeer.send_request(peer, 3, "initialize", %{"protocolVersion" => 1})
      refute_receive {:handler_invoke, :initialize, _, _, _, _}, 200
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 3
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()

      ScriptedPeer.send_request(peer, 4, "session/new", new_session_params())

      %{ctx: ctx3} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      assert ctx3.caps == ctx2.caps
    end
  end
end

# Connection: the §9 failure-mode table rows the invariant suites do not
# cover, transport decode errors (S5) and to_wire totality (O6).
defmodule Raxol.AgentClientProtocol.ConnectionFailureModesTest do
  # async: false -- several tests use `:erlang.system_info(:atom_count)`
  # (node-wide) and the package-level named `SessionRegistry` singleton
  # (Inv-20/21, session/cancel routing); both need exclusive scheduling,
  # matching the precedent in `method_table_test.exs`/`session_test.exs`.
  use Raxol.AgentClientProtocol.Test.ConnectionCase, async: false

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest

  # §9. Failure-mode table -- rows not already exercised above (cited by row
  # number). Rows covered elsewhere: 1/2 (Inv-15), 3/5 (Inv-6), 4/7 (Inv-7),
  # 6/13 (Inv-5), 9 (Inv-11), 11 (Inv-14), 12 (Inv-6/16), 15 (§8.2/Inv-1..3),
  # 21/24 (§8.4/§8.7/Inv-4), 31 (see note below), 33/34 (§8.6/Inv-12/13),
  # 36 (Inv-3), 40 (Inv-9).

  describe "failure-mode table (remaining rows)" do
    test "row 8: notification before handshake is dropped, logged, connection stays usable" do
      %{conn: conn, peer: peer} = start_agent_conn()

      ScriptedPeer.send_notification(peer, "session/cancel", %{"sessionId" => "irrelevant"})
      ScriptedPeer.assert_no_frame(peer, 150)

      complete_handshake(peer)
      assert Process.alive?(conn)
    end

    test "row 10: inbound request with a null id -> -32600 with null id, never dispatched" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_raw(peer, %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "method" => "session/new",
        "params" => new_session_params()
      })

      refute_receive {:handler_invoke, :new_session, _, _, _, _}, 200
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == nil
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()
    end

    test "row 14: handler returns a malformed term for a request -> -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 95, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> :totally_bogus_return_value end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 95
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
    end

    test "row 16: response id right value wrong wire type is a miss -> caller times out" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row16,
          150
        )

      frame = ScriptedPeer.recv(peer)
      id = frame["id"]

      ScriptedPeer.send_result(peer, Integer.to_string(id), %{"content" => "wrong-type-id"})
      refute_receive {:acp_result, :row16, {:ok, _}}, 100
      assert_receive {:acp_result, :row16, {:error, :timeout}}, 500
    end

    test "row 17: a response whose result fails typed decode delivers {:result_decode, _}" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row17,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame["id"], %{"nope" => "no content field here"})
      assert_receive {:acp_result, :row17, {:error, {:result_decode, _reason}}}, 500
    end

    test "row 18: peer answers the same id twice -> second is a late/unknown-id no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row18,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "first"})
      assert_receive {:acp_result, :row18, {:ok, %{content: "first"}}}

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "second"})
      refute_receive {:acp_result, :row18, _}, 150
      assert Process.alive?(conn)
    end

    test "row 19: an unprompted null-id error response is dropped without disturbing later traffic" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_raw(peer, %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => -32_700, "message" => "Parse error"}
      })

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row19,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "ok"})
      assert_receive {:acp_result, :row19, {:ok, %{content: "ok"}}}
    end

    test "row 20: $/cancel_request for an unknown/finished id is a silent no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_cancel_request(peer, 123_456)
      ScriptedPeer.assert_no_frame(peer, 150)
      assert Process.alive?(conn)
    end

    test "row 22: $/cancel_request with a type-coerced id has zero effect (exact-type policy)" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 5, "session/new", new_session_params())

      %{task_pid: t5} =
        handle_next_invoke(:new_session, fn _req, _ctx ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
          end
        end)

      # wrong wire type ("5" string vs the integer id 5 actually in flight)
      ScriptedPeer.send_cancel_request(peer, "5")
      send(t5, :go)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 5
      assert frame["result"]["sessionId"] == "s1"
    end

    test "row 23: $/cancel_request sent AS A REQUEST gets -32601 (it's a notification-only row)" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 60, "$/cancel_request", %{"requestId" => 1})
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 60
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()
    end

    test "row 25: session/cancel for an unknown session_id is a Registry-miss no-op" do
      start_supervised!(Session.Supervisor.registry_child_spec())
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_session_cancel(peer, "no-such-session")
      refute_receive {:"$gen_cast", _}, 150
      assert Process.alive?(conn)
    end

    test "row 26: session/cancel sent AS A REQUEST gets -32601" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 61, "session/cancel", %{"sessionId" => "x"})
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 61
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()
    end

    # Row 27 hands `reply/3` an obligation the Connection never issued, which is
    # the same "no live obligation" branch as a double reply.
    @tag expect_invariant: [[:raxol, :acp, :dup_reply]]
    test "row 27: reply/3 on a totally unknown reply_ref is a suppressed no-op returning :ok" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      assert :ok = Connection.reply(conn, make_ref(), {:ok, %{}})
      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "row 28: :deferred without a prior delegate_reply is a contract breach -> -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 70, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> :deferred end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 70
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
    end

    test "row 29: adopter dies with a live, non-cancelled entry -> -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      adopter = spawn(fn -> Process.sleep(:infinity) end)
      ScriptedPeer.send_request(peer, 80, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn _req, ctx ->
        :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, adopter)
        :deferred
      end)

      Process.exit(adopter, :kill)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 80
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
    end

    test "row 30: adopter dies on a cancelled entry -> one -32800 frame" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      adopter = spawn(fn -> Process.sleep(:infinity) end)
      ScriptedPeer.send_request(peer, 81, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn _req, ctx ->
        :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, adopter)
        send(test_pid, :delegated_81)
        :deferred
      end)

      # see Inv-4/Inv-19's identical note: wait for delegate_reply to have
      # landed before racing the cancel notification in, or the cancel can
      # arrive while `adopter` is still nil and take the undelegated branch.
      assert_receive :delegated_81, 500
      ScriptedPeer.send_cancel_request(peer, 81)

      wait_until(fn ->
        match?(%{cancelled?: true}, Map.get(:sys.get_state(conn).pending_in, 81))
      end)

      Process.exit(adopter, :kill)
      assert %{"id" => 81, "error" => %{"code" => -32_800}} = ScriptedPeer.recv(peer)
      ScriptedPeer.assert_no_frame(peer, 200)
    end

    test "row 35: a stale transport_ref message is dropped without disturbing the connection" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      send(
        conn,
        {:acp_transport, make_ref(),
         {:message,
          %{
            "jsonrpc" => "2.0",
            "id" => 90,
            "method" => "session/new",
            "params" => new_session_params()
          }}}
      )

      refute_receive {:handler_invoke, :new_session, _, _, _, _}, 200
      ScriptedPeer.assert_no_frame(peer, 100)
      assert Process.alive?(conn)
    end

    test "row 37: cancel_request with an unknown tag is a plain :ok no-op" do
      %{conn: conn} = start_agent_conn()
      assert :ok = Connection.cancel_request(conn, :never_submitted)
    end

    test "row 38: async owner already dead at delivery time is a plain send no-op; entry still clears" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      owner = spawn(fn -> Process.sleep(:infinity) end)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          owner,
          :row38,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      Process.exit(owner, :kill)
      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "x"})

      wait_until(fn -> not Map.has_key?(:sys.get_state(conn).pending_out, frame["id"]) end)
      assert Process.alive?(conn)
    end

    test "row 39: an unexpected handle_info message is a debug-logged no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      send(conn, :totally_unexpected_message)

      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 1
    end

    test "row 41: the caller of request/4 dies while parked; entry still clears via the response path" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      caller =
        spawn(fn ->
          Connection.request(conn, "fs/read_text_file", ReadTextFileRequest.new("s", "/f"), 5000)
        end)

      frame = ScriptedPeer.recv(peer)
      cref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^cref, :process, ^caller, :killed}, 500

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "x"})

      wait_until(fn -> not Map.has_key?(:sys.get_state(conn).pending_out, frame["id"]) end)
      assert Process.alive?(conn)
    end

    # row 31 ("transport send_message fails on outbound request") could not
    # be constructed against Transport.Paired: Paired's only failure mode is
    # `closed`, and closing either side ALSO immediately delivers
    # `{:closed, _}` to the Connection's owner, which (§3) tears the
    # Connection down to `phase: :closed` before a subsequent outbound call
    # ever reaches the `transport_mod.send_message/2` call site -- the
    # observable becomes row-conflated `{:error, :connection_closed}` from
    # the phase gate, not row 31's `{:error, {:transport, reason}}` from a
    # live connection whose transport fails a single send. Exercising row 31
    # faithfully needs a transport stub that can fail one `send_message/2`
    # call without an accompanying close/DOWN signal -- out of scope for the
    # Paired-only harness this suite was asked to drive.
  end

  # S5: `-32700` parse-error emission for the transport's own decode-failure
  # channel. `Transport.Paired` (used everywhere else in this suite) passes
  # pre-decoded Elixir terms through unchanged and can never produce this
  # message; `Transport.Stdio` delivers it for a torn/non-JSON line, a
  # decoded-but-non-object top-level term, or an oversized frame (see that
  # module's moduledoc). Simulated here at the wire-message level, matching
  # the technique row 35's stale-transport-ref test already uses to drive
  # `handle_info/2` directly.

  describe "S5: transport decode_error -> -32700 / -32600, connection survives" do
    test "torn/non-JSON line yields -32700; a batch array yields -32600; any other scalar yields -32700" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      %{transport_ref: ref} = :sys.get_state(conn)

      # torn JSON -- before the fix, Connection had no clause for
      # `{:decode_error, ...}` and it fell to the silent catch-all at the
      # bottom of `handle_info/2`: the peer got nothing, ever, and any
      # in-flight request on the other side would eventually time out
      # instead of seeing a proper parse-error response.
      send(
        conn,
        {:acp_transport, ref,
         {:decode_error, %Jason.DecodeError{data: "{\"jsonrpc\":", position: 11, token: nil},
          "{\"jsonrpc\":"}}
      )

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == nil
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.parse_error_code()

      # a decoded-but-non-object top-level array is the same "batch" shape
      # the `is_list(frame)` clause of `Connection.Inbound.message/3` answers -32600
      # for over a pre-decoded-term transport (Paired); over a real
      # byte-level transport it arrives here as `{:not_an_object, list}`
      # instead -- this is the only way to reach that clause over Stdio.
      send(conn, {:acp_transport, ref, {:decode_error, {:not_an_object, [1, 2]}, "[1,2]"}})

      frame2 = ScriptedPeer.recv(peer)
      assert frame2["id"] == nil
      assert frame2["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()

      # a non-list, non-object top-level scalar is a parse error, not a batch.
      send(conn, {:acp_transport, ref, {:decode_error, {:not_an_object, 42}, "42"}})

      frame3 = ScriptedPeer.recv(peer)
      assert frame3["id"] == nil
      assert frame3["error"]["code"] == Raxol.AgentClientProtocol.Error.parse_error_code()

      # the connection never tears down (Inv-15 parity) and stays fully
      # functional afterward.
      assert Process.alive?(conn)

      ScriptedPeer.send_request(peer, 500, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      drain = ScriptedPeer.recv(peer)
      assert drain["id"] == 500
    end
  end

  # O6: `to_wire/1` must be total. Before the fix it piped through
  # `Jason.encode!/1`, so a non-JSON-safe `params` value (a stray pid, ref, or
  # tuple -- app misuse, not a protocol violation `Connection` should ever be
  # trusted to survive) raised `Protocol.UndefinedError` INSIDE the
  # Connection's own `handle_call`, killing the GenServer. A library must not
  # die on caller misuse: the encode failure is surfaced to the caller as
  # `{:error, {:encode, reason}}` and the Connection stays alive.

  describe "O6: to_wire is total (never raises on a non-JSON-safe param)" do
    test "notify/3 with a non-encodable param returns an encode error; Connection stays alive" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      assert {:error, {:encode, %Protocol.UndefinedError{}}} =
               Connection.notify(conn, "session/update", self())

      assert Process.alive?(conn)
      ScriptedPeer.assert_no_frame(peer, 100)

      # the Connection is provably still serving requests, not merely alive
      ScriptedPeer.send_request(peer, 501, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:ok, Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse.new("s-o6")}
      end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 501
      assert frame["result"]["sessionId"] == "s-o6"
    end

    test "request/4 with a non-encodable param returns an encode error; Connection stays alive" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      assert {:error, {:encode, %Protocol.UndefinedError{}}} =
               Connection.request(conn, "fs/read_text_file", {self(), :bad_tuple}, 500)

      assert Process.alive?(conn)
      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "async_request/6 with a non-encodable param answers the owner instead of the connection dying" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      assert {:error, {:encode, %Protocol.UndefinedError{}}} =
               Connection.async_request(conn, "fs/read_text_file", make_ref(), self(), :o6, 500)

      refute_receive {:acp_result, :o6, _}, 100
      assert Process.alive?(conn)
      ScriptedPeer.assert_no_frame(peer, 100)
    end
  end
end

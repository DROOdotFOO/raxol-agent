defmodule Raxol.AgentClientProtocol.SessionTest do
  @moduledoc """
  Session-layer invariants of `acp-supervision-design.md` v2, the turn
  lifecycle half (happy path, I3..I7, I16, the §6.2/6.3 sequence diagrams),
  exercised against `FakeConnection` (which double-checks the IC surface the
  Session consumes is sufficient). Isolation, cleanup and cross-connection
  cases are in `session_isolation_test.exs`; fixtures in
  `Raxol.AgentClientProtocol.Test.SessionCase`.
  """
  use Raxol.AgentClientProtocol.Test.SessionCase, async: false

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  # ---------------------------------------------------------------------------
  # Happy path + I2 register-before-respond
  # ---------------------------------------------------------------------------

  describe "happy path" do
    test "6.1: prompt streams updates then resolves with a single PromptResponse", ctx do
      conn = new_conn()
      sid = "sess-" <> hex()

      {session, _} =
        start_session(ctx, conn,
          session_id: sid,
          turn_runner: runner_posts_then_ends([mode_notif(sid)])
        )

      {res, reply_ref} = begin(session)
      assert res == :ok
      wait_for_reply(conn)

      log = FakeConnection.log(conn)
      assert {:delegate_reply, ^reply_ref, ^session} = hd(log)
      assert FakeConnection.count(conn, :notify) == 1

      assert [{:reply, ^reply_ref, {:ok, %PromptResponse{stop_reason: :end_turn}}}] =
               FakeConnection.entries(conn, :reply)
    end

    test "I2: the session resolves in the Registry before start returns", ctx do
      conn = new_conn()
      sid = "sess-" <> hex()

      opts = [
        session_id: sid,
        conn: conn,
        conn_mod: FakeConnection,
        task_sup: ctx.task_sup,
        turn_runner: runner_ends(:end_turn)
      ]

      {:ok, pid} = SessionSup.start_session(ctx.session_sup, opts)
      # start_child has returned ⇒ init ran ⇒ :via registration is already visible.
      assert [{^pid, _}] = Registry.lookup(Session.registry(), {conn, sid})
    end
  end

  # ---------------------------------------------------------------------------
  # I3 ordering, I4 hold-open
  # ---------------------------------------------------------------------------

  describe "begin_prompt when delegation fails" do
    for result <- [{:error, :cancelled}, {:error, :unknown_ref}] do
      test "delegate_reply #{inspect(result)} runs no turn and sends no reply", ctx do
        conn = new_conn(delegate_result: unquote(Macro.escape(result)))
        test_pid = self()

        {session, _} =
          start_session(ctx, conn,
            turn_runner: fn _s, _r ->
              send(test_pid, :ran)
              {:stop, :end_turn}
            end
          )

        assert {{:error, %Error{code: -32_800, data: nil}}, _ref} = begin(session)
        refute_receive :ran, 100
        assert turn_state(session) == :idle
        assert FakeConnection.count(conn, :reply) == 0
      end
    end
  end

  describe "I3 update/response ordering" do
    test "every update frame precedes the turn's response frame", ctx do
      conn = new_conn()
      sid = "sess-" <> hex()

      {session, _} =
        start_session(ctx, conn,
          session_id: sid,
          turn_runner: runner_posts_then_ends([mode_notif(sid), mode_notif(sid)])
        )

      {:ok, _} = begin(session)
      wait_for_reply(conn)

      log = FakeConnection.log(conn)
      reply_idx = Enum.find_index(log, fn e -> elem(e, 0) == :reply end)
      notify_idxs = for {e, i} <- Enum.with_index(log), elem(e, 0) == :notify, do: i
      assert length(notify_idxs) == 2
      assert Enum.all?(notify_idxs, fn i -> i < reply_idx end)
    end

    test "a post_update on a drained turn returns :turn_over and emits no frame", ctx do
      conn = new_conn()
      {session, sid} = start_session(ctx, conn, turn_runner: runner_ends(:end_turn))
      {:ok, _} = begin(session)
      wait_for_reply(conn)
      assert turn_state(session) == :idle

      before = FakeConnection.count(conn, :notify)
      assert {:error, :turn_over} = Session.post_update(session, mode_notif(sid))
      assert FakeConnection.count(conn, :notify) == before
    end
  end

  describe "I4 hold-turn-open" do
    test "the response waits until every turn-group task is down", ctx do
      conn = new_conn()
      test = self()

      runner = fn s, _req ->
        {:ok, _} =
          Session.spawn_task(s, fn ->
            send(test, {:sub_up, self()})
            receive(do: (:release -> :ok))
          end)

        # root returns instantly; the subagent is still alive
        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)

      assert_receive {:sub_up, sub}, 1_000
      # root has completed but the subagent holds the turn open ⇒ no reply yet
      wait_until(fn ->
        match?({:prompting, %{outcome: {:stop, :end_turn}}}, turn_state(session))
      end)

      assert FakeConnection.count(conn, :reply) == 0

      send(sub, :release)
      wait_for_reply(conn)

      assert [{:reply, _, {:ok, %PromptResponse{stop_reason: :end_turn}}}] =
               FakeConnection.entries(conn, :reply)
    end
  end

  # ---------------------------------------------------------------------------
  # I5 cancel priority, I7 exactly-one cancelled, 6.2 cancel mid-permission
  # ---------------------------------------------------------------------------

  describe "I5 cancel outranks a landed root result" do
    test "cancel after root DOWN but before last subagent DOWN ⇒ stopReason cancelled", ctx do
      conn = new_conn()
      test = self()

      runner = fn s, _req ->
        {:ok, _} =
          Session.spawn_task(s, fn ->
            send(test, {:sub_up, self()})
            receive(do: (:release -> :ok))
          end)

        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)

      assert_receive {:sub_up, sub}, 1_000
      # ensure the root's :end_turn has landed in outcome (S2 race window)
      wait_until(fn ->
        match?({:prompting, %{outcome: {:stop, :end_turn}}}, turn_state(session))
      end)

      GenServer.cast(session, {:acp_session_cancel, 99})
      send(sub, :release)

      reply = wait_for_reply(conn)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :cancelled}}} = reply
    end
  end

  describe "I7 exactly one cancelled response" do
    test "cancel mid-turn ⇒ one reply, cancelled; double-cancel adds nothing", ctx do
      conn = new_conn()

      runner = fn _s, _req -> receive(do: (:acp_cancel -> {:stop, :cancelled})) end
      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)

      GenServer.cast(session, {:acp_session_cancel, 1})
      GenServer.cast(session, {:acp_session_cancel, 2})

      reply = wait_for_reply(conn)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :cancelled}}} = reply
      # let any straggler settle, then re-assert exactly one
      Process.sleep(50)
      assert FakeConnection.count(conn, :reply) == 1
    end
  end

  describe "6.2 cancel mid-permission" do
    test "cancel aborts the parked ask (deny), emits cancel_request, resolves cancelled", ctx do
      conn = new_conn(perm_responder: fn _req -> :decline end)
      test = self()

      runner = fn s, _req ->
        res = Session.request_permission(s, :perm_req)
        send(test, {:perm, res})
        receive(do: (:acp_cancel -> :ok))
        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)
      wait_until(fn -> FakeConnection.count(conn, :async_request) == 1 end)

      GenServer.cast(session, {:acp_session_cancel, 7})

      # The parked ask must unblock via the CANCEL path (I9), not by waiting
      # out the 30s backstop. A 1s assert_receive is the order-of-magnitude
      # bound that proves it -- 30x below the backstop, and load-robust (a
      # wall-clock `< 50ms` assert here flaked under scheduling delay while
      # the cancel path was in fact prompt).
      assert_receive {:perm, {:ok, :cancelled}}, 1_000

      # The asker is answered before the client's request is withdrawn
      # (`abort_pending_perms/2`), so the withdrawal can land just after.
      wait_until(fn -> FakeConnection.count(conn, :cancel_request) == 1 end)
      assert FakeConnection.count(conn, :cancel_request) == 1
      reply = wait_for_reply(conn)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :cancelled}}} = reply
    end
  end

  describe "a turn that ends with an ask still parked" do
    test "denies the asker and withdraws the client's request", ctx do
      test = self()

      conn =
        new_conn(
          perm_responder: fn _req ->
            send(test, :asked)
            :decline
          end
        )

      # The ask comes from a process outside the turn's task group, so the
      # root can return while it is parked.
      runner = fn s, _req ->
        spawn(fn -> send(test, {:perm, Session.request_permission(s, :perm_req)}) end)
        send(test, {:runner, self()})
        receive(do: (:end_turn -> {:stop, :end_turn}))
      end

      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)
      assert_receive {:runner, runner_pid}, 1_000
      assert_receive :asked, 1_000
      send(runner_pid, :end_turn)

      assert_receive {:perm, {:ok, :cancelled}}, 1_000
      reply = wait_for_reply(conn)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :end_turn}}} = reply
      assert FakeConnection.count(conn, :cancel_request) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # I6 cancel-of-idle + 6.3 cancel racing prompt dispatch + I16 commutation
  # ---------------------------------------------------------------------------

  describe "I6 cancel-of-idle" do
    test "no frame emitted; only the latch moves; a later prompt runs", ctx do
      conn = new_conn()
      {session, _} = start_session(ctx, conn, turn_runner: runner_ends(:end_turn))

      GenServer.cast(session, {:acp_session_cancel, 5})
      wait_until(fn -> :sys.get_state(session).last_cancel_seq == 5 end)

      assert FakeConnection.log(conn) == []
      assert turn_state(session) == :idle

      # a prompt wire-ordered AFTER the cancel (higher rx_seq) runs normally
      {:ok, _} = begin(session, 6)
      reply = wait_for_reply(conn)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :end_turn}}} = reply
    end
  end

  describe "6.3 / I16 wire-order commutation" do
    test "prompt wire-ordered before a latched cancel is born-cancelled", ctx do
      conn = new_conn()
      # runner would end :end_turn, but born-cancelled must run NOTHING
      {session, _} =
        start_session(ctx, conn,
          turn_runner: fn _s, _r -> flunk("runner must not run for a born-cancelled prompt") end
        )

      GenServer.cast(session, {:acp_session_cancel, 5})
      wait_until(fn -> :sys.get_state(session).last_cancel_seq == 5 end)

      {res, reply_ref} = begin(session, 3)
      assert res == :ok

      reply = wait_for_reply(conn)
      assert {:reply, ^reply_ref, {:ok, %PromptResponse{stop_reason: :cancelled}}} = reply
      assert turn_state(session) == :idle
    end

    test "prompt wire-ordered after the cancel (higher rx_seq) runs unaffected", ctx do
      conn = new_conn()
      {session, _} = start_session(ctx, conn, turn_runner: runner_ends(:end_turn))

      GenServer.cast(session, {:acp_session_cancel, 5})
      wait_until(fn -> :sys.get_state(session).last_cancel_seq == 5 end)

      {:ok, _} = begin(session, 9)
      reply = wait_for_reply(conn)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :end_turn}}} = reply
    end
  end
end

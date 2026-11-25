defmodule Raxol.AgentClientProtocol.SessionIsolationTest do
  @moduledoc """
  Session-layer invariants of `acp-supervision-design.md` v2, the isolation
  half: protocol-error passthrough, fail-closed permission (I8), registry and
  atom hygiene (I11, I14), busy-prompt isolation (I12), the backstop (I13),
  caps and Writer reaping, `$/cancel_request` (I17), set_mode, disconnect,
  interleaved sessions and the cross-connection turn latch (S2).
  """
  use Raxol.AgentClientProtocol.Test.SessionCase, async: false

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Emitter
  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  # Root-result error passthrough

  describe "root result carrying a protocol error" do
    # Folding every unrecognized root result into a bare internal_error would
    # discard a runner's diagnosis and show the peer -32603 with no data --
    # indistinguishable from a crash.
    test "a runner's own Error survives with its data intact", ctx do
      conn = new_conn()
      err = Error.with_data(Error.internal_error(), %{"reason" => "credit balance too low"})

      {session, _sid} =
        start_session(ctx, conn, turn_runner: fn _s, _req -> {:error, err} end)

      begin(session)

      assert {:reply, _, {:error, %Error{data: %{"reason" => "credit balance too low"}}}} =
               wait_for_reply(conn)
    end

    test "an unrecognized shape still folds to a bare internal error", ctx do
      conn = new_conn()

      {session, _sid} =
        start_session(ctx, conn, turn_runner: fn _s, _req -> :nonsense end)

      begin(session)

      assert {:reply, _, {:error, %Error{code: -32_603, data: nil}}} = wait_for_reply(conn)
    end
  end

  # I8 fail-closed permission matrix

  describe "I8 fail-closed permission" do
    test "only a decoded selected outcome yields allow; every other row denies", ctx do
      selected = %RequestPermissionResponse{
        outcome: {:selected, SelectedPermissionOutcome.new("opt-1")}
      }

      rows = [
        {{:ok, selected}, {:ok, {:selected, %SelectedPermissionOutcome{option_id: "opt-1"}}}},
        {{:ok, %RequestPermissionResponse{outcome: :cancelled}}, {:ok, :cancelled}},
        {{:error, Error.internal_error()}, {:ok, :cancelled}},
        {{:error, {:result_decode, :bad}}, {:ok, :cancelled}},
        {{:error, :timeout}, {:ok, :cancelled}},
        {{:error, :connection_closed}, {:ok, :cancelled}}
      ]

      for {outcome, expected} <- rows do
        conn = new_conn(perm_responder: fn _req -> outcome end)
        test = self()

        runner = fn s, _req ->
          res = Session.request_permission(s, :perm_req)
          send(test, {:perm, res})
          {:stop, :end_turn}
        end

        {session, _} = start_session(ctx, conn, turn_runner: runner)
        {:ok, _} = begin(session)

        assert_receive {:perm, ^expected},
                       1_000,
                       "row #{inspect(outcome)} should map to #{inspect(expected)}"

        wait_for_reply(conn)
      end
    end
  end

  # I11 registry pruning, I12 busy isolation, I13 backstop, I14 no atoms

  describe "I11 no stale registry entries" do
    test "a dead session's key is pruned by the Registry monitor", ctx do
      conn = new_conn()
      {session, sid} = start_session(ctx, conn, turn_runner: runner_ends(:end_turn))
      assert [{^session, _}] = Registry.lookup(Session.registry(), {conn, sid})

      Process.exit(session, :kill)
      wait_until(fn -> Registry.lookup(Session.registry(), {conn, sid}) == [] end)
    end
  end

  describe "I12 busy-prompt isolation" do
    test "a second prompt on a prompting session errors; the first is undisturbed", ctx do
      conn = new_conn()
      runner = fn _s, _req -> receive(do: (:go -> {:stop, :end_turn})) end
      {session, _} = start_session(ctx, conn, turn_runner: runner)

      {:ok, first_ref} = begin(session, 1)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)
      {:prompting, t0} = turn_state(session)

      {res, _} = begin(session, 2)
      assert {:error, %Error{code: -32_600}} = res
      # in-flight turn untouched
      assert {:prompting, t1} = turn_state(session)
      assert t1.turn_ref == t0.turn_ref
      assert t1.reply_ref == first_ref

      send(t0.root_pid, :go)
      wait_for_reply(conn)
      assert FakeConnection.count(conn, :reply) == 1
    end
  end

  describe "I13 backstop" do
    test "a runner that ignores :acp_cancel still resolves cancelled via kill", ctx do
      conn = new_conn()
      runner = fn _s, _req -> Process.sleep(:infinity) end

      {session, _} =
        start_session(ctx, conn, turn_runner: runner, config: %{cancel_backstop_ms: 40})

      {:ok, _} = begin(session)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)

      GenServer.cast(session, {:acp_session_cancel, 1})
      reply = wait_for_reply(conn, 1_000)
      assert {:reply, _, {:ok, %PromptResponse{stop_reason: :cancelled}}} = reply
    end

    test "a stale backstop (wrong turn_ref) never touches the live turn", ctx do
      conn = new_conn()
      runner = fn _s, _req -> receive(do: (:go -> {:stop, :end_turn})) end
      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)
      {:prompting, t} = turn_state(session)

      send(session, {:cancel_backstop, make_ref()})
      Process.sleep(30)
      # the live turn survives: same turn, root still alive, no reply
      assert {:prompting, t2} = turn_state(session)
      assert t2.turn_ref == t.turn_ref
      assert Process.alive?(t.root_pid)
      assert FakeConnection.count(conn, :reply) == 0

      send(t.root_pid, :go)
      wait_for_reply(conn)
    end
  end

  # Per-connection session cap (durable-sessions robustness): a peer cannot open
  # unbounded Sessions on one connection. The Nth+1 is refused CLEANLY.

  describe "per-connection session cap" do
    test "the (cap+1)th session is refused with {:error, :max_children}", ctx do
      capped = start_supervised!({SessionSup, [max_sessions: 2]}, id: :capped_session_sup)
      conn = new_conn()

      start = fn sid ->
        SessionSup.start_session(capped,
          session_id: sid,
          conn: conn,
          conn_mod: FakeConnection,
          task_sup: ctx.task_sup,
          turn_runner: runner_ends(:end_turn)
        )
      end

      assert {:ok, _} = start.("cap-1")
      assert {:ok, _} = start.("cap-2")
      # Over the cap: refused cleanly (no crash, no leak) — not silently accepted.
      assert {:error, :max_children} = start.("cap-3")
    end
  end

  # Idle reaping of the durable Writer (durable-sessions robustness): a
  # long-lived node must not accrue a never-stopped Writer per session forever.
  # After the idle timeout the Session idle-STOPS its Writer; the journal is the
  # durable state and survives, so a fresh reattach respawns + replays (the moat).

  describe "idle Writer reaping (journal survives)" do
    test "an idle session stops its Writer after the timeout; the journal is intact", ctx do
      start_supervised!({Registry, keys: :unique, name: Writer.registry()})
      sid = "sess-idle-" <> hex()
      {:ok, j} = Mem.open(sid)

      writer =
        start_supervised!(%{
          id: {:writer, sid},
          start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}]]},
          restart: :temporary
        })

      conn = new_conn()

      {session, _} =
        start_session(ctx, conn,
          session_id: sid,
          emitter: Emitter.Journal,
          turn_runner: runner_ends(:end_turn),
          config: %{idle_timeout: 120, cancel_backstop_ms: 50}
        )

      # Drive one turn so the journal holds durable records (genesis + boundaries)
      # — this is what a reattach later replays.
      {:ok, _} = begin(session, 1)
      wait_for_reply(conn)
      wait_until(fn -> turn_state(session) == :idle end)

      assert Process.alive?(writer)
      hwm_before = Mem.high_watermark(j)
      assert hwm_before > 0

      # After the idle timeout the Session reaps its Writer (registry entry gone,
      # process down) — the journal store is owned elsewhere and is untouched.
      wait_until(fn -> Writer.whereis(sid) == nil end)
      refute Process.alive?(writer)
      assert Mem.high_watermark(j) == hwm_before

      # The idle Session itself is gone too (it is :temporary — reattach respawns).
      wait_until(fn -> not Process.alive?(session) end)
    end
  end

  describe "I14 no atom creation from session data" do
    test "session_id churn does not grow the atom table", ctx do
      conn = new_conn()

      # warm up code paths once so first-load atoms don't skew the measurement
      {s0, _} = start_session(ctx, conn, session_id: "warmup-" <> hex())
      DynamicSupervisor.terminate_child(ctx.session_sup, s0)

      before = :erlang.system_info(:atom_count)

      for _ <- 1..50 do
        sid = "sess-" <> hex()

        {:ok, pid} =
          SessionSup.start_session(ctx.session_sup,
            session_id: sid,
            conn: conn,
            conn_mod: FakeConnection,
            task_sup: ctx.task_sup,
            turn_runner: runner_ends(:end_turn)
          )

        DynamicSupervisor.terminate_child(ctx.session_sup, pid)
      end

      assert :erlang.system_info(:atom_count) == before
    end
  end

  # I17 $/cancel_request on the prompt id

  describe "I17 / S7 $/cancel_request on the prompt id" do
    test "the drain STILL calls reply/3 for the cancelled id (releases pending_in, S7)", ctx do
      # After a $/cancel_request the Session still calls `reply/3`: that
      # `cancelled` reply is the id's one response and releases the entry.
      conn = new_conn()

      runner = fn _s, _req ->
        receive do
          :acp_cancel -> {:stop, :cancelled}
          :finish -> {:stop, :end_turn}
        end
      end

      {session, _} = start_session(ctx, conn, turn_runner: runner)

      {:ok, reply_ref} = begin(session)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)

      send(session, {:acp_reply_cancelled, reply_ref})
      wait_until(fn -> turn_state(session) == :idle end)

      # The release signal: reply/3 was called for the cancelled reply_ref (was
      # SKIPPED before the fix ⇒ pending_in leak). The Connection pops + suppresses.
      assert [{:reply, ^reply_ref, {:ok, %PromptResponse{stop_reason: :cancelled}}}] =
               FakeConnection.entries(conn, :reply)

      # And the session is back to :idle and accepts a fresh prompt.
      {:ok, _} = begin(session, 2)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)
      {:prompting, t} = turn_state(session)
      send(t.root_pid, :finish)
      wait_until(fn -> FakeConnection.count(conn, :reply) == 2 end)

      assert [
               {:reply, ^reply_ref, {:ok, %PromptResponse{stop_reason: :cancelled}}},
               {:reply, _, {:ok, %PromptResponse{stop_reason: :end_turn}}}
             ] = FakeConnection.entries(conn, :reply)
    end
  end

  # mode_state seam (§2.3) + set_mode

  describe "set_mode (§2.3)" do
    test "validates against mode_state; legal mid-turn", ctx do
      conn = new_conn()

      modes =
        SessionModeState.new("ask", [
          SessionMode.new("ask", "Ask"),
          SessionMode.new("code", "Code")
        ])

      runner = fn _s, _req -> receive(do: (:go -> {:stop, :end_turn})) end
      {session, _} = start_session(ctx, conn, turn_runner: runner, mode_state: modes)

      {:ok, _} = begin(session)
      wait_until(fn -> match?({:prompting, _}, turn_state(session)) end)

      assert {:ok, _} = Session.set_mode(session, "code")
      assert :sys.get_state(session).mode_state.current_mode_id == "code"
      assert {:error, %Error{code: -32_602}} = Session.set_mode(session, "nope")

      {:prompting, t} = turn_state(session)
      send(t.root_pid, :go)
      wait_for_reply(conn)
    end

    test "a nil mode_state makes set_mode invalid-params", ctx do
      conn = new_conn()
      {session, _} = start_session(ctx, conn, mode_state: nil)
      assert {:error, %Error{code: -32_602}} = Session.set_mode(session, "code")
    end
  end

  # 6.4 disconnect mid-turn, 6.5 two sessions interleaving, I15 independence

  describe "6.4 disconnect mid-turn (fail-closed)" do
    test "connection_closed on a parked ask denies the tool call", ctx do
      conn = new_conn(perm_responder: fn _req -> {:error, :connection_closed} end)
      test = self()

      runner = fn s, _req ->
        send(test, {:perm, Session.request_permission(s, :perm_req)})
        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, conn, turn_runner: runner)
      {:ok, _} = begin(session)
      assert_receive {:perm, {:ok, :cancelled}}, 1_000
    end
  end

  describe "6.5 two sessions interleaving on one connection" do
    test "each session's updates precede its own response; turns are independent", ctx do
      conn_a = new_conn()
      conn_b = new_conn()
      sid_a = "sess-a-" <> hex()
      sid_b = "sess-b-" <> hex()

      {sa, _} =
        start_session(ctx, conn_a,
          session_id: sid_a,
          turn_runner: runner_posts_then_ends([mode_notif(sid_a)])
        )

      {sb, _} =
        start_session(ctx, conn_b,
          session_id: sid_b,
          turn_runner: runner_posts_then_ends([mode_notif(sid_b)])
        )

      {:ok, _} = begin(sa, 1)
      {:ok, _} = begin(sb, 1)

      wait_for_reply(conn_a)
      wait_for_reply(conn_b)

      for conn <- [conn_a, conn_b] do
        log = FakeConnection.log(conn)
        reply_idx = Enum.find_index(log, fn e -> elem(e, 0) == :reply end)
        notify_idx = Enum.find_index(log, fn e -> elem(e, 0) == :notify end)
        assert notify_idx < reply_idx
        assert FakeConnection.count(conn, :reply) == 1
      end
    end
  end

  # S2 / §2.7 cross-connection turn latch (Writer is the arbiter)

  describe "S2 cross-connection turn latch (reattach §2.7)" do
    # With N connections attached to ONE session_id, N Session processes exist
    # (SessionRegistry keys are {conn_pid, session_id}), so the supervision I12
    # per-process busy row cannot arbitrate across connections. The Writer's turn
    # latch is the v1 arbiter: a `turn_started` append while a turn is in flight
    # returns {:error, :turn_in_flight}, and THAT makes begin_prompt reply busy —
    # spawn nothing, append nothing, one clean turn in the journal.
    test "the second Session's prompt replies busy, runs nothing, corrupts no journal", ctx do
      start_supervised!({Registry, keys: :unique, name: Writer.registry()})
      sid = "sess-shared-" <> hex()
      {:ok, j} = Mem.open(sid)

      start_supervised!(%{
        id: {:writer, sid},
        start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}]]},
        restart: :temporary
      })

      # Two connections ⇒ two Session processes for one session_id, both journalled.
      conn_a = new_conn()
      conn_b = new_conn()
      test = self()

      runner_a = fn _s, _req -> receive(do: (:go -> {:stop, :end_turn})) end

      {sa, _} =
        start_session(ctx, conn_a,
          session_id: sid,
          emitter: Emitter.Journal,
          turn_runner: runner_a
        )

      {sb, _} =
        start_session(ctx, conn_b,
          session_id: sid,
          emitter: Emitter.Journal,
          turn_runner: fn _s, _r ->
            send(test, :b_ran)
            {:stop, :end_turn}
          end
        )

      # A begins: its turn_started acquires the shared Writer's latch.
      {:ok, ref_a} = begin(sa, 1)
      wait_until(fn -> match?({:prompting, _}, turn_state(sa)) end)
      wait_until(fn -> length(kinds(j, "turn_started")) == 1 end)

      # B begins on the SAME session_id: the Writer's latch is held ⇒ busy.
      {res_b, ref_b} = begin(sb, 1)
      assert res_b == :ok, "B takes the deferred path (delegated), then replies busy"

      wait_until(fn -> FakeConnection.count(conn_b, :reply) == 1 end)

      assert [{:reply, ^ref_b, {:error, %Error{code: -32_600}}}] =
               FakeConnection.entries(conn_b, :reply)

      # B ran NOTHING and appended NOTHING: no b_ran, still exactly one turn_started,
      # zero turn_completed, and B is back to :idle (never entered :prompting).
      refute_receive :b_ran, 100
      assert turn_state(sb) == :idle
      assert length(kinds(j, "turn_started")) == 1
      assert kinds(j, "turn_completed") == []

      # A finishes cleanly: exactly one turn_started + one turn_completed. No
      # interleave, no double completion, latch released.
      send_root(sa, :go)
      wait_until(fn -> FakeConnection.count(conn_a, :reply) == 1 end)

      assert [{:reply, ^ref_a, {:ok, %PromptResponse{stop_reason: :end_turn}}}] =
               FakeConnection.entries(conn_a, :reply)

      wait_until(fn -> length(kinds(j, "turn_completed")) == 1 end)
      assert length(kinds(j, "turn_started")) == 1
      assert length(kinds(j, "turn_completed")) == 1

      # Latch released ⇒ B's retry now succeeds and drives its own clean turn (the
      # runner is non-blocking, so B may pass through :prompting too fast to observe;
      # key on the side-effect + the journal instead).
      {:ok, _ref_b2} = begin(sb, 2)
      assert_receive :b_ran, 1_000
      wait_until(fn -> length(kinds(j, "turn_started")) == 2 end)
      wait_until(fn -> length(kinds(j, "turn_completed")) == 2 end)
    end
  end

  # A Journal-emitter turn runner blocks on `:go` in the root task; this reaches it.
  defp send_root(session, msg) do
    {:prompting, t} = turn_state(session)
    send(t.root_pid, msg)
  end

  defp kinds(j, kind) do
    hwm = Mem.high_watermark(j)
    {:ok, records} = Mem.read(j, 1, max(hwm, 1))
    Enum.filter(records, &(&1.kind == kind))
  end
end

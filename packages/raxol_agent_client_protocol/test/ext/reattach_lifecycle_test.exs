defmodule Raxol.AgentClientProtocol.Ext.ReattachLifecycleTest do
  @moduledoc """
  The reattach subscriber's lifetime over the ACP wire: Lagged and
  `$/cancel_request` stop the live tail, fail-closed attach (J9), a live turn
  filling the journal end-to-end, and the supervised subscriber. Fixtures in
  `Raxol.AgentClientProtocol.Test.ReattachCase`.
  """

  use Raxol.AgentClientProtocol.Test.ReattachCase, async: false

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Ext.Reattach
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  # -- Subscriber consumer clauses (unit): Lagged + cancel both stop the tail --

  describe "subscriber lifecycle — Lagged and $/cancel_request stop the live tail" do
    test "on {:reattach_lagged, …} the subscriber emits its OWN forward_hi then stops" do
      # A direct-delivery unit test of the consumer clause (the manufactured send
      # that USED to masquerade as J6): the Writer's 3rd element is conservative;
      # the SUBSCRIBER's own forward counter is what goes on the wire (exactness).
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      last = List.last(delivered_offsets(conn))
      assert last == Mem.high_watermark(j)

      mon = Process.monitor(sub)
      send(sub, {:reattach_lagged, sid, 999})

      # Terminal: emit Lagged, then STOP (no lingering detached process).
      assert_receive {:DOWN, ^mon, :process, ^sub, :normal}, 500

      lagged =
        Enum.find(notifies(conn), fn {:notify, m, _} ->
          m == "_raxol/session.lagged"
        end)

      assert {:notify, "_raxol/session.lagged", %{"lastOffset" => ^last}} =
               lagged
    end

    test "on {:acp_reply_cancelled, ref} the subscriber unsubscribes and stops (no further frames)" do
      # S3: the Subscriber is the adopter (delegate_reply), so a $/cancel_request
      # on the load reaches it as {:acp_reply_cancelled, reply_ref}. The peer
      # abandoned the request ⇒ the live tail MUST stop.
      {sid, j, w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      before = length(delivered_offsets(conn))

      mon = Process.monitor(sub)
      send(sub, {:acp_reply_cancelled, ref})
      assert_receive {:DOWN, ^mon, :process, ^sub, :normal}, 500

      # It unsubscribed from the Writer — severed from the live tail.
      assert %{subscribers: subs} = :sys.get_state(w)
      assert subs == %{}

      # A subsequent live append reaches NO further frame (subscriber gone).
      {:ok, _} = Writer.append(w, "session_update", %{"i" => 2}, "agent")
      Process.sleep(20)
      assert length(delivered_offsets(conn)) == before
    end

    test "a non-matching {:acp_reply_cancelled, other_ref} does NOT stop the subscriber" do
      # Only the subscriber's OWN reply_ref cancels it; a stray ref falls through
      # to the catch-all no-op (a different request's cancel must not tear us down).
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {_conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      mon = Process.monitor(sub)
      send(sub, {:acp_reply_cancelled, make_ref()})
      refute_receive {:DOWN, ^mon, :process, ^sub, _}, 100
      assert Process.alive?(sub)
    end
  end

  # -- J7: turn_completed totality / finalize-from-replay ---------------------

  test "J7 — a reattacher finalizes a turn from replay (turn_started matched by turn_completed)" do
    {sid, j, _w} =
      start_writer([
        {"turn_started", %{"turnId" => 4, "prompt" => []}, "user"},
        {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
        {"turn_completed", %{"turnId" => 4, "stopReason" => "end_turn"}, "system"}
      ])

    {conn, _ref, sub, :deferred} = attach(sid, j)
    _ = sync(sub)

    # The reattacher replays through turn_started AND the persisted
    # turn_completed (delivered as a first-class _raxol/session.record).
    records =
      for {:notify, "_raxol/session.record", p} <- notifies(conn),
          do: {p["kind"], p["payload"]}

    assert Enum.any?(records, fn {k, p} ->
             k == "turn_started" and p["turnId"] == 4
           end)

    assert Enum.any?(records, fn {k, p} ->
             k == "turn_completed" and p["turnId"] == 4 and
               p["stopReason"] == "end_turn"
           end)

    # Totality: in the durable substream every turn_started is matched by exactly
    # one turn_completed for its turnId.
    {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
    started = for r <- recs, r.kind == "turn_started", do: r.payload["turnId"]

    completed =
      for r <- recs, r.kind == "turn_completed", do: r.payload["turnId"]

    assert Enum.sort(started) == Enum.sort(completed)
  end

  # -- fromOffset > h + 1 rejected --------------------------------------------

  test "fromOffset > h + 1 is rejected -32602 (minting a gap is illegal), carries highWatermark" do
    {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
    h = Mem.high_watermark(j)

    {conn, ref, sub, :deferred} = attach(sid, j, %{from_offset: h + 2})
    _ = sync(sub)

    assert {:reply, ^ref, {:error, %Error{code: -32_602} = err}} =
             reply_entry(conn)

    assert err.data == %{"highWatermark" => h}
    # Nothing was delivered — a rejected attach reads no history.
    assert delivered_offsets(conn) == []

    # fromOffset == h + 1 is LEGAL (a gap-free "tip").
    {conn2, ref2, sub2, :deferred} = attach(sid, j, %{from_offset: h + 1})
    _ = sync(sub2)
    assert {:reply, ^ref2, {:ok, _}} = reply_entry(conn2)
  end

  # -- CDI-6: force-close at grant.expires_at ---------------------------------

  test "force-close at grant.expires_at cuts the live tail (CDI-6 [G5:S7])" do
    {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
    now = System.os_time(:second)

    # expires_at already reached ⇒ the timer fires immediately (delay 0).
    {conn, _ref, sub, :deferred} =
      attach(sid, j, %{
        authorize: fn _ctx -> {:ok, grant(%{expires_at: now})} end,
        now: now
      })

    ref = Process.monitor(sub)
    assert_receive {:DOWN, ^ref, :process, ^sub, :normal}, 1_000

    closed =
      Enum.find(notifies(conn), fn {:notify, m, _} ->
        m == "_raxol/session.closed"
      end)

    assert {:notify, "_raxol/session.closed", %{"reason" => "revoked"}} = closed
  end

  # -- J9: fail-closed attach --------------------------------------------------

  describe "J9 — fail-closed attach (the CDI-1 funnel contract)" do
    test "a {:denied, _} verdict ⇒ -32000 deny envelope, NO registration, NO history, NO reply" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      res =
        Reattach.attach(%{
          conn: conn,
          conn_mod: FakeConnection,
          session_id: sid,
          reply_ref: make_ref(),
          journal: {Mem, j},
          authorize: fn _ctx -> {:denied, :not_local} end
        })

      # The CDI-5 deny envelope: -32000 "attach denied", NO data (anti-oracle).
      assert {:error, %Error{code: -32_000, message: "attach denied", data: nil}} = res

      # Nothing registered, no history read, no delegate/reply — a denied
      # attacher never appears in the subscriber set even transiently.
      assert FakeConnection.log(conn) == []
      # The live Writer has no subscribers.
      assert %{subscribers: subs} = :sys.get_state(Writer.whereis(sid))
      assert subs == %{}
    end

    test "a non-conforming authorize return (not {:ok, grant}) also denies (fail-closed)" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      for verdict <- [
            :ok,
            true,
            {:ok, :not_a_grant_but_atom} |> elem(0),
            {:error, :boom}
          ] do
        res =
          Reattach.attach(%{
            conn: conn,
            conn_mod: FakeConnection,
            session_id: sid,
            reply_ref: make_ref(),
            journal: {Mem, j},
            authorize: fn _ctx -> verdict end
          })

        assert {:error, %Error{code: -32_000}} = res
      end

      assert FakeConnection.log(conn) == []
    end

    test "via the REAL Runner + LocalNode policy: nil transport denies, :process grants" do
      sup = start_supervised!({Task.Supervisor, []})
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])

      real_authorize = fn ctx ->
        Runner.authorize(LocalNode, ctx, task_supervisor: sup)
      end

      # Deny: LocalNode fails closed on a nil/absent transport (CDI-2) ⇒ -32000.
      {conn_d, _rd, _sub_d, res_d} =
        attach(sid, j, %{authorize: real_authorize, transport: nil})

      assert {:error, %Error{code: -32_000}} = res_d
      assert FakeConnection.log(conn_d) == []

      # Grant: an in-BEAM :process transport is OS-co-resident ⇒ the real Runner
      # returns a well-formed %Grant{}; the attach proceeds and replies.
      {conn_g, ref_g, sub_g, res_g} =
        attach(sid, j, %{
          authorize: real_authorize,
          transport: %{kind: :process, peer: self()}
        })

      assert res_g == :deferred
      _ = sync(sub_g)
      assert {:reply, ^ref_g, {:ok, _}} = reply_entry(conn_g)
      assert delivered_offsets(conn_g) == durable_offsets(j)
    end
  end

  # -- §3.4: stock projection --------------------------------------------------

  test "§3.4 stock projection: a non-offset-aware attacher gets session_update kinds only" do
    {sid, j, _w} =
      start_writer([
        {"turn_started", %{"turnId" => 1, "prompt" => []}, "user"},
        {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
        {"turn_completed", %{"turnId" => 1, "stopReason" => "end_turn"}, "system"}
      ])

    {conn, _ref, sub, :deferred} = attach(sid, j, %{offset_aware?: false})
    _ = sync(sub)

    methods = for {:notify, m, _} <- notifies(conn), do: m
    # No _raxol/* frames for a stock attacher; only session/update.
    refute Enum.any?(methods, &String.starts_with?(&1, "_raxol/"))
    assert Enum.all?(methods, &(&1 == "session/update"))

    # Only the session_update-kind record (offset 3) is projected onto the wire;
    # genesis/turn_started/turn_completed are kind-projected away (NOT taint).
    assert delivered_offsets(conn) == [3]
  end

  # -- Session→journal emit seam (§2.4): a LIVE turn fills the durable journal --
  #
  # The reattach reds above drive a standalone Writer directly. This closes the
  # loop end-to-end: a real `Session` wired with `Emitter.Journal` runs a prompt
  # turn; its `session/update` + turn boundaries must land DURABLY through the
  # single-publisher Writer (J10 durability leg), and a later reattacher must
  # replay the exact durable substream (J1) — the origin turn is the producer,
  # the reattacher is a pure consumer of the same offset-addressed log.

  describe "Session Emitter.Journal — a live turn fills the journal end-to-end" do
    alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
    alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
    alias Raxol.AgentClientProtocol.Session
    alias Raxol.AgentClientProtocol.Session.Emitter.Journal, as: JournalEmitter
    alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup

    test "updates + turn boundaries are durable; a reattacher replays the substream" do
      start_supervised!(SessionSup.registry_child_spec())
      sid = "sess-" <> hex()
      {:ok, j} = Mem.open(sid)

      # The single publisher over the SHARED Mem handle (origin appends land here;
      # the reattacher reads the same store).
      _writer =
        start_supervised!(
          %{
            id: {:writer, sid},
            start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}]]},
            restart: :temporary
          },
          restart: :temporary
        )

      task_sup = start_supervised!({Task.Supervisor, []}, id: {:task_sup, sid})
      {:ok, origin_conn} = FakeConnection.start_link()

      notif =
        SessionNotification.new(
          sid,
          {:current_mode_update, CurrentModeUpdate.new("code")}
        )

      runner = fn s, _req ->
        :ok = Session.post_update(s, notif)
        {:stop, :end_turn}
      end

      {:ok, session} =
        Session.start_link(
          session_id: sid,
          conn: origin_conn,
          conn_mod: FakeConnection,
          task_sup: task_sup,
          turn_runner: runner,
          emitter: JournalEmitter,
          journal: {Mem, j}
        )

      # Drive one prompt turn; wait for the async turn task to reply.
      reply_ref = make_ref()
      assert :ok = Session.begin_prompt(session, %{prompt: [%{}]}, reply_ref, 1)
      wait_reply(origin_conn)

      # The origin still got its live session/update via the direct notify path
      # (base behavior preserved) AND its prompt response.
      assert Enum.any?(notifies(origin_conn), fn {:notify, m, _} ->
               m == "session/update"
             end)

      assert {:reply, ^reply_ref, {:ok, _}} = reply_entry(origin_conn)

      # DURABLE: genesis(1), turn_started(2), session_update(3), turn_completed(4).
      {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))
      kinds = Enum.map(recs, & &1.kind)

      assert kinds == [
               "session_created",
               "turn_started",
               "session_update",
               "turn_completed"
             ]

      started = Enum.find(recs, &(&1.kind == "turn_started"))
      completed = Enum.find(recs, &(&1.kind == "turn_completed"))

      # J7 totality + single-render equality: the turn_completed carries the same
      # turnId and the rendered stopReason that fed the prompt response.
      assert started.payload["turnId"] == 1
      assert completed.payload["turnId"] == 1
      assert completed.payload["stopReason"] == "end_turn"

      # A reattacher (a different connection) replays the EXACT durable substream
      # (J1) — the origin turn was subscriber-agnostic; the log is the contract.
      {conn2, _ref2, sub2, :deferred} = attach(sid, j)
      _ = sync(sub2)
      assert delivered_offsets(conn2) == durable_offsets(j)
      assert delivered_offsets(conn2) == [1, 2, 3, 4]
    end
  end

  # Wave-6 conformance finding 13: the attach Subscriber must be supervised
  # under the per-connection Session DynamicSupervisor (ctx.session_sup), NOT
  # bare-linked to the ephemeral handler task (whose :normal exit never signals
  # a plain link, leaking the Subscriber past the connection forever).
  describe "supervised subscriber lifetime (finding 13)" do
    test "default start supervises the Subscriber under session_sup; it dies with it" do
      {sid, j, _w} = start_writer()
      {:ok, conn} = FakeConnection.start_link()
      sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      # NO injected :start_subscriber — exercise the DEFAULT path with a real
      # session_sup (the exact production wiring).
      assert :deferred =
               Reattach.attach(%{
                 conn: conn,
                 conn_mod: FakeConnection,
                 session_id: sid,
                 reply_ref: make_ref(),
                 journal: {Mem, j},
                 authorize: fn _ctx -> {:ok, grant()} end,
                 session_sup: sup
               })

      # The Subscriber is a child of session_sup (supervised), not orphaned.
      children = DynamicSupervisor.which_children(sup)
      assert [{:undefined, sub, :worker, _}] = children
      assert is_pid(sub) and Process.alive?(sub)

      # Killing the session subtree takes the Subscriber with it — no leak.
      ref = Process.monitor(sub)
      :ok = Supervisor.stop(sup)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}, 500
      refute Process.alive?(sub)
    end

    test "with neither session_sup nor start_subscriber, falls back to unsupervised start" do
      {sid, j, _w} = start_writer()
      {:ok, conn} = FakeConnection.start_link()

      # No session_sup, no injected start_subscriber: the documented fallback
      # still attaches (the caller owns lifetime on this path).
      assert :deferred =
               Reattach.attach(%{
                 conn: conn,
                 conn_mod: FakeConnection,
                 session_id: sid,
                 reply_ref: make_ref(),
                 journal: {Mem, j},
                 authorize: fn _ctx -> {:ok, grant()} end
               })
    end
  end
end

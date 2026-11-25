defmodule Raxol.AgentClientProtocol.Ext.ReattachTest do
  @moduledoc """
  The reattach SEAM over the ACP wire (`acp-reattach-design.md` §4, the frozen
  `harness-bus-protocol.md` §4). These are the P-BUS-shaped reds — the Wave 6
  conformance contours — driven against the REAL single-publisher Writer
  (`Ext.Journal.Writer` + `Ext.Journal.Mem`) and a `FakeConnection` standing in
  for the wire, so "delivered" means the ordered `Connection.notify`/`reply`
  frames a client actually sees.

  Every positive contour ships its named dead-injector negative control (bus §9).

  Coverage map:

    * J1  — replay closure over the wire (history ++ live == durable substream,
      no gap/dup, incl. turn-boundary kinds) + dead taint-filter breaks closure.
    * J2  — register-before-`h`, decision-time `h`, permanent monotone gate at
      the boundary + dead register-after-history (gap) + dead cached-counter (gap).
    * J4  — writerless attach = history-only, NO error + dead attach-requires-writer.
    * J5  — taint annotated, never dropped (delivery counts == record counts).
    * J6  — Lagged heals from `last_offset + 1` + dead reattach-from-last_offset (dup).
    * J7  — turn_completed replays/finalizes a turn (totality: every turn_started
      is matched by exactly one turn_completed in the durable substream).
    * `fromOffset > h + 1` rejected (`-32602`, minting a gap is illegal).
    * force-close at `grant.expires_at` cuts the live tail (CDI-6 `[G5:S7]`).
    * fail-closed attach (`{:denied, _}` ⇒ `-32000`, no registration/history) [J9].
    * §3.4 stock projection (offset-aware? = false ⇒ session_update kinds only).

  J9, the subscriber lifecycle and the end-to-end journal turn are in
  `reattach_lifecycle_test.exs`, review edge cases in
  `reattach_edge_cases_test.exs`; the fixtures in
  `Raxol.AgentClientProtocol.Test.ReattachCase`.
  """

  use Raxol.AgentClientProtocol.Test.ReattachCase, async: false

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer

  # J1: replay closure over the wire

  describe "J1 — replay closure (P-JS5) over the ACP wire" do
    test "history ++ live == the durable substream, no gap, no dup, incl. turn kinds" do
      {sid, j, w} =
        start_writer([
          {"turn_started", %{"turnId" => 1, "prompt" => []}, "user"},
          {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
          {"session_update", %{"sessionUpdate" => "agent_message_chunk"}, "agent"},
          {"turn_completed", %{"turnId" => 1, "stopReason" => "end_turn"}, "system"}
        ])

      # Durable so far: 1 genesis, 2 turn_started, 3-4 updates, 5 turn_completed.
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      h = Mem.high_watermark(j)
      assert h == 5
      # History delivered exactly the durable substream 1..h, in order.
      assert delivered_offsets(conn) == Enum.to_list(1..5)

      # Live tail: a new turn appends 6,7,8; each delivered once, offset > h.
      {:ok, _} =
        Writer.append(
          w,
          "turn_started",
          %{"turnId" => 2, "prompt" => []},
          "user"
        )

      {:ok, _} =
        Writer.append(
          w,
          "session_update",
          %{"sessionUpdate" => "plan"},
          "agent"
        )

      {:ok, _} =
        Writer.append(
          w,
          "turn_completed",
          %{"turnId" => 2, "stopReason" => "end_turn"},
          "system"
        )

      _ = sync(sub)

      # Union (history ++ live) == full durable stream, offset-sorted, no dup.
      assert delivered_offsets(conn) == durable_offsets(j)
      assert delivered_offsets(conn) == Enum.to_list(1..8)
    end

    test "DEAD taint-filter breaks closure (a taint filter drops records ⇒ history != durable)" do
      {sid, j, _w} =
        start_writer([
          {"session_update", %{"i" => 1}, "agent"},
          {"session_update", %{"i" => 2}, "external"},
          {"session_update", %{"i" => 3}, "agent"}
        ])

      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      # The real seam NEVER filters by taint: every offset is delivered.
      assert delivered_offsets(conn) == durable_offsets(j)

      # Dead control: a HYPOTHETICAL taint-filtering delivery (drop "external")
      # would omit offset 3's record ⇒ delivered ⊊ durable ⇒ closure broken.
      {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))

      filtered =
        recs |> Enum.reject(&(&1.taint == "external")) |> Enum.map(& &1.offset)

      refute filtered == durable_offsets(j)
    end
  end

  # J2: register-before-h, decision-time h, permanent monotone gate

  describe "J2 — register-before-h + decision-time h + gate armed before live" do
    test "permanent monotone gate: offset <= h dropped forever, offset > h forwarded once" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      # Durable 1 genesis, 2 update ⇒ h = 2.
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      assert delivered_offsets(conn) == [1, 2]

      before = length(delivered_offsets(conn))

      # A live record with offset <= h is a leftover already in history ⇒ dropped.
      _ = live(sub, sid, 2)
      _ = live(sub, sid, 1)
      assert length(delivered_offsets(conn)) == before

      # offset > h ⇒ forwarded, exactly once, in order.
      _ = live(sub, sid, 3)
      _ = live(sub, sid, 4)
      assert delivered_offsets(conn) == [1, 2, 3, 4]
    end

    test "DEAD register-after-history: a record appended in the window is missed (gap)" do
      # Correct path: subscribe FIRST, so a record appended after h-read arrives
      # live and closure holds.
      {sid_ok, j_ok, w_ok} =
        start_writer([{"session_update", %{"i" => 1}, "agent"}])

      {conn_ok, _r, sub_ok, :deferred} =
        attach(sid_ok, j_ok, %{
          __between__: fn ->
            {:ok, _} =
              Writer.append(w_ok, "session_update", %{"i" => 2}, "agent")
          end
        })

      _ = sync(sub_ok)

      # 1 genesis, 2 first update (history), 3 the between-append (live) — no gap.
      assert delivered_offsets(conn_ok) == [1, 2, 3]

      # DEAD path: read h + history BEFORE subscribing. The between-append lands
      # after history was read and before subscription ⇒ neither in history nor
      # live ⇒ a permanent gap.
      {sid_bad, j_bad, w_bad} =
        start_writer([{"session_update", %{"i" => 1}, "agent"}])

      {conn_bad, _r2, sub_bad, :deferred} =
        attach(sid_bad, j_bad, %{
          __dead_register_after_history__: true,
          __between__: fn ->
            {:ok, _} =
              Writer.append(w_bad, "session_update", %{"i" => 2}, "agent")
          end
        })

      _ = sync(sub_bad)
      assert delivered_offsets(conn_bad) == [1, 2]
      refute 3 in delivered_offsets(conn_bad)
      assert 3 in durable_offsets(j_bad)
    end

    test "DEAD cached-counter high_watermark mis-places the boundary (gap)" do
      {sid, j, _w} =
        start_writer([
          {"session_update", %{"i" => 1}, "agent"},
          {"session_update", %{"i" => 2}, "agent"}
        ])

      # Correct: decision-time h from the store delivers all durable offsets.
      {conn_ok, _r, sub_ok, :deferred} = attach(sid, j)
      _ = sync(sub_ok)
      assert delivered_offsets(conn_ok) == durable_offsets(j)

      # DEAD: a cached counter (h = 0) reads NO history ⇒ every pre-existing
      # record is missed (history empties) ⇒ gap vs the durable stream.
      {conn_bad, _r2, sub_bad, :deferred} =
        attach(sid, j, %{__dead_cached_counter__: true})

      _ = sync(sub_bad)
      assert delivered_offsets(conn_bad) == []
      refute delivered_offsets(conn_bad) == durable_offsets(j)
    end
  end

  # J4: writerless attach = history-only, NO error

  describe "J4 — writerless attach" do
    test "no live Writer ⇒ history-only, replies normally, NO error, no live frames" do
      {sid, j} =
        dumped_journal([
          {"session_created", %{"cwd" => "/tmp"}, "system"},
          {"session_update", %{"i" => 1}, "agent"}
        ])

      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      # History byte-identical to a live attach's history for the same offsets.
      assert delivered_offsets(conn) == durable_offsets(j)

      # Replies normally with the highWatermark, and it is NOT an error.
      assert {:reply, ^ref, {:ok, resp}} = reply_entry(conn)

      assert get_in(resp._meta, ["raxol.io", "highWatermark"]) ==
               Mem.high_watermark(j)

      # No live tail was armed: a stray live message is ignored (live: :none).
      before = length(delivered_offsets(conn))
      _ = live(sub, sid, 99)
      assert length(delivered_offsets(conn)) == before
    end

    test "DEAD attach-requires-writer would error; the correct path does NOT" do
      {sid, j} = dumped_journal([{"session_update", %{"i" => 1}, "agent"}])
      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      assert {:reply, ^ref, {:ok, _}} = reply_entry(conn)
      refute match?({:reply, ^ref, {:error, _}}, reply_entry(conn))
    end

    test "never-seen session (no Writer, empty journal) ⇒ -32002 resource_not_found" do
      sid = "sess-" <> hex()
      {:ok, j} = Mem.open(sid)
      {conn, ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)
      assert {:reply, ^ref, {:error, %Error{code: -32_002}}} = reply_entry(conn)
    end
  end

  # J5: taint annotated, never dropped

  test "J5 — every delivered frame carries the record taint; counts == record counts" do
    taints = ~w(user agent external system)

    {sid, j, _w} =
      start_writer(Enum.map(taints, fn t -> {"session_update", %{"t" => t}, t} end))

    {conn, _ref, sub, :deferred} = attach(sid, j)
    _ = sync(sub)

    # Genesis is "system"; then one update per taint.
    delivered = frame_taints(conn)
    for t <- taints, do: assert(t in delivered)

    # Per-taint delivery count == per-taint record count (no drop by taint).
    {:ok, recs} = Mem.read(j, 1, Mem.high_watermark(j))

    assert Enum.frequencies(delivered) ==
             Enum.frequencies(Enum.map(recs, & &1.taint))
  end

  # J6: Lagged heals from last_offset + 1
  #
  # J6 drives REAL lag through a Writer with a
  # tiny `:journal_subscriber_credit` (area B's producer) so the runtime emits
  # the Lagged, then asserts the client heals from `last_offset + 1` losslessly.
  # The subscriber's consumer-clause reaction (emit terminal Lagged on its OWN
  # forward_hi, then stop) is its own separately-named unit test below.

  # Credit replenishment: a HEALTHY forwarding subscriber never false-lags
  #
  # The Writer decrements a per-subscriber publish credit (default 1024) on every
  # live send; the Subscriber calls `Writer.credit/3` after each forward, so
  # credit tracks 'unforwarded backlog', not 'total-ever-sent'. Without that a
  # healthy subscriber false-lags after 1024 sends.

  describe "credit replenishment — a healthy subscriber never false-lags" do
    test "forwards >1024 live frames, replenishing credit each, stays attached, NO lagged" do
      # Default per-subscriber credit is 1024; publish MORE than that (2000).
      {sid, j, w} = start_writer([{"session_update", %{"i" => 0}, "agent"}])
      {conn, _ref, sub, :deferred} = attach(sid, j)
      _ = sync(sub)

      mon = Process.monitor(sub)
      h = Mem.high_watermark(j)

      n = 2000
      batch = 200

      # Append in drained batches: send 2000
      # (>> 1024) lifetime frames while keeping the UNFORWARDED backlog per
      # batch (200) well under the 1024 credit -- genuine backlog > credit is
      # real backpressure, tested separately. Draining (sub) then flushing the
      # Writer (:sys.get_state processes the per-forward credit casts) between
      # batches makes this deterministic, instead of relying on the scheduler
      # to interleave forwarding into a single 2000-deep burst (which starved
      # under a loaded suite and flaked).
      for b <- 0..(div(n, batch) - 1) do
        for i <- (b * batch + 1)..(b * batch + batch),
            do: {:ok, _} = Writer.append(w, "session_update", %{"i" => i}, "agent")

        _ = sync(sub)
        _ = :sys.get_state(w)
      end

      # Healthy: it never lagged and never stopped.
      refute_receive {:DOWN, ^mon, :process, ^sub, _}, 200
      assert Process.alive?(sub)

      refute Enum.any?(notifies(conn), fn {:notify, m, _} ->
               m == "_raxol/session.lagged"
             end)

      # ALL n live frames were forwarded, in order, once each (offsets h+1..h+n).
      live_offsets = for o <- delivered_offsets(conn), o > h, do: o
      assert live_offsets == Enum.to_list((h + 1)..(h + n))

      # Still in the Writer's subscriber set (not dropped).
      assert map_size(:sys.get_state(w).subscribers) == 1
    end
  end

  describe "J6 — Lagged disconnect and lossless heal (REAL runtime lag)" do
    test "Lagged carries the subscriber's own last-forwarded offset; +1 heals dup-free" do
      # A healthy Subscriber replenishes credit per forwarded frame, so a tiny
      # credit does not false-lag it. Real backpressure is a subscriber that
      # does NOT drain — here a raw non-draining probe subscribed straight to
      # the single publisher. Its credit
      # is never returned, so the exhausting publish makes the Writer PRODUCE
      # {:reattach_lagged, sid, last_offset} carrying the highest offset it actually
      # sent this subscriber (= the subscriber's last-received offset),
      # deterministically — no timing race. (The Subscriber's own forward_hi going
      # on the WIRE is the separate consumer-clause unit test below.)
      {sid, j, w} =
        start_writer(
          [{"session_update", %{"i" => 0}, "agent"}],
          subscriber_credit: 1
        )

      # A stuck subscriber: this test process collects live frames but NEVER calls
      # Writer.credit/3, so credit runs down and stays down.
      probe = self()
      :ok = Writer.subscribe(w, probe)

      # First live publish fits the 1 credit; the next exhausts it ⇒ the Writer
      # emits the terminal Lagged for the probe and drops it. (Assertions below do
      # not hardcode the triggering offset — any reasonable accounting greens this.)
      for i <- 1..5,
          do: {:ok, _} = Writer.append(w, "session_update", %{"i" => i}, "agent")

      # The Writer PRODUCED the heal signal itself, carrying the highest offset it
      # actually sent this subscriber (selectively received past the live frames).
      assert_receive {:reattach_lagged, ^sid, last_offset}
      assert is_integer(last_offset)

      # Heal: a fresh reattach from last_offset + 1 ⇒ the union is gap/dup-free.
      {conn2, _r2, sub2, :deferred} =
        attach(sid, j, %{from_offset: last_offset + 1})

      _ = sync(sub2)
      hwm = Mem.high_watermark(j)
      expected = Enum.filter(1..hwm//1, &(&1 > last_offset))
      assert delivered_offsets(conn2) == expected
      # No offset the client already held (<= last_offset) is re-delivered.
      refute Enum.any?(delivered_offsets(conn2), &(&1 <= last_offset))
    end

    test "DEAD reattach-from-last_offset re-delivers last_offset (dup)" do
      {sid, j, _w} =
        start_writer([
          {"session_update", %{"i" => 1}, "agent"},
          {"session_update", %{"i" => 2}, "agent"}
        ])

      last = Mem.high_watermark(j)

      # Correct heal (last + 1): last_offset is NOT re-delivered.
      {conn_ok, _r, sub_ok, :deferred} =
        attach(sid, j, %{from_offset: last + 1})

      _ = sync(sub_ok)
      refute last in delivered_offsets(conn_ok)

      # DEAD (reattach from last_offset itself): re-delivers last_offset ⇒ dup.
      {conn_bad, _r2, sub_bad, :deferred} = attach(sid, j, %{from_offset: last})
      _ = sync(sub_bad)
      assert last in delivered_offsets(conn_bad)
    end
  end
end

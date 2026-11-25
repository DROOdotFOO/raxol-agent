defmodule Raxol.Broker.JournalRecoveryTest do
  @moduledoc """
  Journal write deadlines, crash recovery, lifecycle and damage (see
  `Raxol.Broker.Test.JournalCase`).
  """
  use Raxol.Broker.Test.JournalCase, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Intent, Journal, Policy}
  alias Raxol.Broker.Journal.Replay
  alias Raxol.Broker.Test.{ExecutorIdentity, JournalCase}

  @t0 JournalCase.t0()
  @day JournalCase.day()

  describe "write timeouts" do
    # A stall is simulated with :sys.suspend; a trace session on
    # GenServer.call/3 shows the deadline each call was made with, so no test
    # waits for a timer to fire.
    setup do
      trace = :trace.session_create(:broker_journal_timeouts, self(), [])
      on_exit(fn -> :trace.session_destroy(trace) end)
      1 = :trace.function(trace, {GenServer, :call, 3}, true, [])
      {:ok, trace: trace}
    end

    # A claimant that writes a reviewed, allowed group and then writes
    # `placing` when told to. A journal that stops while `placing` waits
    # makes the call exit; the placer returns that as `{:exit, reason}`.
    defp placer(name, intent, ctx) do
      parent = self()

      placer =
        Task.async(fn ->
          ExecutorIdentity.assume!(name)
          {:ok, id} = Journal.open_group(intent, ctx, name)

          placed_entries(intent, ctx)
          |> Enum.take(3)
          |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))

          send(parent, {:reviewed, id})

          receive do
            :go ->
              try do
                Journal.append_to_group(id, {:placing}, name)
              catch
                :exit, {reason, {GenServer, :call, _}} -> {:exit, reason}
              end
          end
        end)

      assert_receive {:reviewed, id}
      {placer, id}
    end

    test "placing waits on a stalled journal by default, and lands",
         %{opts: opts, trace: trace} do
      name = opts[:name]
      journal = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      intent = limit("2")
      {placer, id} = placer(name, intent, context())

      1 = :trace.process(trace, placer.pid, true, [:call])
      :ok = :sys.suspend(journal)
      send(placer.pid, :go)

      # The call is made while the journal is suspended, with no deadline.
      assert_receive {:trace, _, :call,
                      {GenServer, :call, [^name, {:append_to_group, ^id, {:placing}}, :infinity]}}

      :ok = :sys.resume(journal)
      assert Task.await(placer, :infinity) == :ok
      assert {:ok, ^id} = Journal.placing_for_intent(intent.id, name)
    end

    # F3: the Writer stalls (a slow fsync) past the 5 s FileStore default
    # while `placing` is appended. The journal waits up to its write deadline
    # (default 60 s), so a slow write within it lands.
    test "placing waits on a stalled Writer up to the write deadline, and lands",
         %{opts: opts, path: path, trace: trace} do
      name = opts[:name]
      journal = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      writer = writer!(path)
      intent = limit("2")
      {placer, id} = placer(name, intent, context())

      1 = :trace.process(trace, journal, true, [:call])
      :ok = :sys.suspend(writer)
      send(placer.pid, :go)

      # The journal calls its suspended Writer with the default deadline.
      assert_receive {:trace, ^journal, :call,
                      {GenServer, :call,
                       [^writer, {:append_many, [%{"type" => "placing"}]}, 60_000]}}

      :ok = :sys.resume(writer)
      assert Task.await(placer, :infinity) == :ok
      assert {:ok, ^id} = Journal.placing_for_intent(intent.id, name)
      assert {:ok, [^id]} = Journal.open_groups(name)
      assert %{"type" => "placing", "group_id" => ^id} = List.last(records(path))
    end

    # Past the deadline the write may still land, so the journal never
    # answers it with an error: it kills the Writer and stops. The Writer is
    # suspended, so the killed request was never processed and `placing`
    # never reached disk; recovery closes the group as no order sent.
    test "a Writer stalled past the write deadline is killed and the journal stops",
         %{opts: opts, path: path} do
      name = opts[:name]

      journal =
        start_supervised!(
          Supervisor.child_spec({Journal, Keyword.put(opts, :write_deadline, 200)},
            restart: :temporary
          )
        )

      writer = writer!(path)
      intent = limit("2")
      {placer, id} = placer(name, intent, context())
      journal_ref = Process.monitor(journal)
      writer_ref = Process.monitor(writer)

      :ok = :sys.suspend(writer)
      send(placer.pid, :go)

      assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}, 5_000
      assert_receive {:DOWN, ^journal_ref, :process, ^journal, {:writer_stalled, 200}}, 5_000
      assert Task.await(placer, :infinity) == {:exit, {:writer_stalled, 200}}
      refute Enum.any?(records(path), &(&1["type"] == "placing"))

      start!(opts)
      assert Journal.status(name) == :ok

      assert %{
               "type" => "close",
               "group_id" => ^id,
               "reason" => "crash_before_verdict",
               "outcome" => "deny"
             } = List.last(records(path))

      assert Journal.placing_for_intent(intent.id, name) == {:ok, nil}
      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
    end

    test "an invalid write deadline refuses to start", %{opts: opts} do
      Process.flag(:trap_exit, true)

      for deadline <- [0, -1, :infinity, 4_294_967_296] do
        assert Journal.start_link(Keyword.put(opts, :write_deadline, deadline)) ==
                 {:error, {:journal_open_failed, :invalid_write_deadline}}
      end
    end

    test "a caller-supplied timeout bounds the call, and the queued write still lands",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      {:ok, id} = Journal.open_group(limit("2"), context(), name)
      before = length(records(path))

      :ok = :sys.suspend(journal)
      assert {:timeout, _} = catch_exit(Journal.append_to_group(id, {:review, %{}}, name, 0))
      :ok = :sys.resume(journal)

      # This is why the default is :infinity: the caller gave up, but the
      # journal still wrote the record once it ran.
      assert {:ok, [^id]} = Journal.open_groups(name)
      assert length(records(path)) == before + 1
    end
  end

  describe "crash recovery" do
    test "killing the writer between intent and verdict closes the group as DENY, uncounted",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      {:ok, crashed} = Journal.open_group(limit("4"), ctx, name)

      kill_writer!(path, journal)

      # Read-side, before any restart: the open group already renders as DENY.
      assert {:ok, lines} = Replay.run(path, ~D[2026-10-02])
      assert Enum.any?(lines, &(&1 =~ "outcome  DENY crash_before_verdict (open on disk"))

      start!(opts)
      assert Journal.status(name) == :ok

      close = List.last(records(path))

      assert %{
               "type" => "close",
               "group_id" => ^crashed,
               "reason" => "crash_before_verdict",
               "outcome" => "deny"
             } = close

      assert Journal.today_notional(@day, name) == {:ok, d("250")}
      assert Journal.orders_last_minute(@t0, name) == {:ok, 1}

      assert {:ok, lines} = Replay.run(path, ~D[2026-10-02])
      assert Enum.count(lines, &(&1 =~ "outcome  DENY crash_before_verdict")) == 1

      assert Journal.append_to_group(crashed, {:review, %{}}, name) ==
               {:error, {:unknown_or_finished_group, crashed}}
    end

    test "a crash after the post-review ALLOW but before placing is a DENY, uncounted",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      intent = limit("4")
      ctx = context()
      id = in_flight!(name, limit("2"), ctx)
      :ok = Journal.append_to_group(id, {:order, :placed, %{}}, name)

      {:ok, crashed} = Journal.open_group(intent, ctx, name)

      placed_entries(intent, ctx)
      |> Enum.take(3)
      |> Enum.each(&(:ok = Journal.append_to_group(crashed, &1, name)))

      kill_writer!(path, journal)
      start!(opts)

      assert %{
               "group_id" => ^crashed,
               "reason" => "crash_before_verdict",
               "outcome" => "deny"
             } = List.last(records(path))

      assert counters(name, @t0) == {{:ok, d("250")}, {:ok, 1}}
    end

    test "an approved ASK placed and then crashed is an unknown outcome, counted at placing",
         %{opts: opts, path: path, clock: clock} do
      name = opts[:name]
      journal = start!(opts)
      {:ok, intent} = Intent.limit(:buy, "AAPL", d("4"), d("125"), provenance: :llm)
      ctx = context()
      {:ask, _} = verdict = Policy.evaluate(intent, ctx)

      {:ok, id} = Journal.open_group(intent, ctx, name)
      :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:review, %{"warnings" => []}}, name)
      :ok = Journal.append_to_group(id, {:verdict, :post_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:approval, :approved, "operator"}, name)
      at(clock, DateTime.add(@t0, 10, :second))
      :ok = Journal.append_to_group(id, {:placing}, name)

      placed_at = DateTime.add(@t0, 10, :second)
      live = counters(name, placed_at)
      assert live == {{:ok, d("500")}, {:ok, 1}}

      kill_writer!(path, journal)
      at(clock, ~U[2026-10-03 09:00:00Z])
      start!(opts)

      assert %{
               "group_id" => ^id,
               "reason" => "crash_outcome_unknown",
               "outcome" => "unknown"
             } = List.last(records(path))

      # Counted at the placing record, not at the restart a day later.
      assert counters(name, placed_at) == live
      assert Journal.today_notional(~U[2026-10-03 00:00:00Z], name) == {:ok, d("0")}
    end
  end

  describe "lifecycle" do
    test "a stray message is logged by its tag only", %{opts: opts} do
      pid = start!(opts)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, {:token, "Bearer leak"})
          _ = :sys.get_state(pid)
        end)

      assert log =~ "ignored an unexpected message: {:token, ...}"
      refute log =~ "leak"
    end

    test "a supervisor shutdown stops the Writer the journal started", %{opts: opts, path: path} do
      start!(opts)
      {base, session} = Journal.location(path)
      writer = Writer.whereis(Path.join(base, session))
      ref = Process.monitor(writer)

      stop_supervised!(opts[:name])
      assert_receive {:DOWN, ^ref, :process, ^writer, _reason}
    end

    test "a journal that joined a running Writer stops when that Writer dies",
         %{opts: opts, path: path} do
      {base, session} = Journal.location(path)
      {:ok, handle} = FileStore.open(session, base_dir: base, chain: true)
      Process.unlink(handle.writer)

      journal = start!(opts)
      assert Journal.status(opts[:name]) == :ok

      kill_writer!(path, journal)
    end
  end

  describe "damage" do
    test "a flipped byte on disk refuses every append and query, and replay", %{
      opts: opts,
      path: path
    } do
      name = opts[:name]
      start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      stop_supervised!(name)

      [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))
      bytes = File.read!(segment)
      [first, second, third | _] = String.split(bytes, "\n")
      # A byte in the middle of record 3 (the pre-review verdict).
      at = byte_size(first) + 1 + byte_size(second) + 1 + div(byte_size(third), 2)
      <<pre::binary-size(^at), byte, post::binary>> = bytes
      File.write!(segment, <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>)

      start!(opts)
      assert Journal.status(name) == {:damaged, 3}
      assert Journal.verify(name) == {:broken, 3}
      assert Journal.open_group(limit("1"), ctx, name) == {:error, {:journal_damaged, 3}}
      assert Journal.today_notional(@day, name) == {:error, {:journal_damaged, 3}}
      assert Journal.orders_last_minute(@t0, name) == {:error, {:journal_damaged, 3}}
      assert Replay.run(path, ~D[2026-10-02]) == {:error, {:broken, 3}}
      assert File.read!(segment) == <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>
    end

    test "verify/1 on a running journal catches a change made underneath it", %{
      opts: opts,
      path: path
    } do
      name = opts[:name]
      start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))

      File.write!(
        segment,
        String.replace(File.read!(segment), ~s("qty":"2"), ~s("qty":"9"), global: false)
      )

      assert Journal.verify(name) == {:broken, 1}
      assert Journal.today_notional(@day, name) == {:error, {:journal_damaged, 1}}
      assert Journal.open_group(limit("1"), ctx, name) == {:error, {:journal_damaged, 1}}
    end

    test "verify/1 on a journal whose chain flag was removed reports it and refuses it", %{
      opts: opts,
      path: path
    } do
      name = opts[:name]
      journal = start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      meta = Path.join(path, "meta.json")

      File.write!(
        meta,
        meta |> File.read!() |> Jason.decode!() |> Map.delete("chain") |> Jason.encode!()
      )

      refute Journal.verify(name) == :ok
      assert Process.alive?(journal)
      refute Journal.status(name) == :ok
      assert {:error, _} = Journal.open_group(limit("1"), ctx, name)
      assert {:error, _} = Journal.today_notional(@day, name)
    end
  end
end

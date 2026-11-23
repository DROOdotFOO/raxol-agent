defmodule Raxol.AgentClientProtocol.Test.ReattachCase do
  @moduledoc """
  Shared fixtures for the reattach suites (`test/ext/reattach_*_test.exs`): a
  REAL single-publisher Writer over a test-owned `Ext.Journal.Mem`, a
  `FakeConnection` subscriber attached through `Ext.Reattach.attach/1`, and
  helpers that read the frames a client would see. `use` it in place of
  `ExUnit.Case`; it arms the invariant sentinel and starts the Writer registry.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Record
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Ext.Reattach
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  using do
    quote do
      use Raxol.AgentClientProtocol.Test.InvariantSentinel

      import Raxol.AgentClientProtocol.Test.ReattachCase
    end
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Writer.registry()})
    :ok
  end

  @spec hex() :: String.t()
  def hex, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # A registered Writer over a test-owned Mem journal (the handle outlives the
  # Writer). Genesis (session_created @1) is appended on the first op.
  # `writer_opts` are extra `Writer.start_link/1` opts (e.g. the area-B
  # `:journal_subscriber_credit` knob J6 drives to force REAL lag).
  @spec start_writer([{String.t(), map(), String.t()}], keyword()) :: {String.t(), term(), pid()}
  def start_writer(records \\ [], writer_opts \\ []) do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)

    w =
      start_supervised!(
        %{
          id: {:writer, sid},
          start: {Writer, :start_link, [[session_id: sid, journal: {Mem, j}] ++ writer_opts]},
          restart: :temporary
        },
        restart: :temporary
      )

    Enum.each(records, fn {k, p, t} -> {:ok, _} = Writer.append(w, k, p, t) end)
    {sid, j, w}
  end

  # A writerless (dumped) journal: records appended straight to Mem, no Writer.
  @spec dumped_journal([{String.t(), map(), String.t()}]) :: {String.t(), term()}
  def dumped_journal(records) do
    sid = "sess-" <> hex()
    {:ok, j} = Mem.open(sid)

    Enum.each(records, fn {k, p, t} ->
      {:ok, _} = Mem.append(j, %{kind: k, payload: p, taint: t})
    end)

    {sid, j}
  end

  @spec grant(map()) :: map()
  def grant(fields \\ %{}) do
    Map.merge(
      %{actor: %{"id" => "tester"}, scope: :attach, expires_at: nil, lens: nil},
      fields
    )
  end

  @spec granting() :: (map() -> {:ok, map()})
  def granting, do: fn _ctx -> {:ok, grant()} end

  # Attach a FakeConnection subscriber to `sid`/`j`. Returns {conn, reply_ref,
  # subscriber_pid, attach_result}. The subscriber pid is captured via the
  # injected start_subscriber so gate/lag/expiry can be driven directly.
  @spec attach(String.t(), term(), map()) :: {pid(), reference(), pid() | nil, term()}
  def attach(sid, j, opts \\ %{}) do
    {:ok, conn} = FakeConnection.start_link()
    ref = make_ref()
    test = self()

    base = %{
      conn: conn,
      conn_mod: FakeConnection,
      session_id: sid,
      reply_ref: ref,
      journal: {Mem, j},
      from_offset: 0,
      history_policy: :from_offset,
      offset_aware?: true,
      authorize: granting(),
      start_subscriber: fn o ->
        {:ok, p} = Reattach.start_link(o)
        send(test, {:sub, p})
        {:ok, p}
      end
    }

    res = Reattach.attach(Map.merge(base, opts))

    sub =
      receive do
        {:sub, p} -> p
      after
        50 -> nil
      end

    {conn, ref, sub, res}
  end

  # A mailbox barrier that tolerates a subscriber that already stopped (terminal
  # paths — resource_not_found, fromOffset reject, expiry — reply synchronously
  # during attach's :run call, then {:stop, :normal, ...}).
  @spec sync(pid() | nil) :: term()
  def sync(pid) do
    if is_pid(pid) and Process.alive?(pid), do: :sys.get_state(pid), else: :ok
  catch
    :exit, _ -> :ok
  end

  @spec notifies(pid()) :: list()
  def notifies(conn), do: FakeConnection.entries(conn, :notify)

  @spec frame_offset(String.t(), map()) :: pos_integer() | nil
  def frame_offset("session/update", p),
    do: get_in(p, ["_meta", "raxol.io", "offset"])

  def frame_offset("_raxol/session.record", p), do: p["offset"]
  def frame_offset(_method, _p), do: nil

  # The delivered RECORD substream: the ordered offsets of session/update +
  # _raxol/session.record frames (UX frames caught_up/lagged/closed excluded).
  @spec delivered_offsets(pid()) :: [pos_integer()]
  def delivered_offsets(conn) do
    for {:notify, method, params} <- notifies(conn),
        off = frame_offset(method, params),
        off != nil,
        do: off
  end

  @spec frame_taints(pid()) :: [String.t() | nil]
  def frame_taints(conn) do
    for {:notify, method, params} <- notifies(conn), reduce: [] do
      acc ->
        case method do
          "session/update" ->
            [get_in(params, ["_meta", "raxol.io", "taint"]) | acc]

          "_raxol/session.record" ->
            [params["taint"] | acc]

          _ ->
            acc
        end
    end
    |> Enum.reverse()
  end

  @spec durable_offsets(term()) :: [pos_integer()]
  def durable_offsets(j) do
    hwm = Mem.high_watermark(j)
    {:ok, recs} = Mem.read(j, 1, max(hwm, 1))
    Enum.map(recs, & &1.offset)
  end

  @spec reply_entry(pid()) :: term()
  def reply_entry(conn),
    do: conn |> FakeConnection.entries(:reply) |> List.last()

  # Poll until the origin connection has recorded a prompt reply (the turn task
  # runs async under the Task.Supervisor).
  @spec wait_reply(pid(), non_neg_integer()) :: :ok
  def wait_reply(conn, tries \\ 400)
  def wait_reply(_conn, 0), do: flunk("timed out waiting for the prompt reply")

  def wait_reply(conn, tries) do
    if reply_entry(conn) != nil do
      :ok
    else
      Process.sleep(5)
      wait_reply(conn, tries - 1)
    end
  end

  # A synthetic live publish (as the Writer would send it).
  @spec live(pid(), String.t(), pos_integer(), String.t(), String.t()) :: term()
  def live(sub, sid, offset, kind \\ "session_update", taint \\ "agent") do
    record = %Record{
      offset: offset,
      session_id: sid,
      kind: kind,
      payload: %{"o" => offset},
      taint: taint,
      ts_hook: 0
    }

    send(sub, {:reattach_live, sid, record})
    sync(sub)
  end
end

defmodule Raxol.AgentClientProtocol.Test.SlowRecordConn do
  @moduledoc false
  # A conn_mod double that delegates to FakeConnection but sleeps ONCE, on the
  # first `_raxol/session.record` history frame, long enough to push the
  # synchronous replay past the default 5s `GenServer.call` window (replay
  # must run under `:infinity`, not the default timeout).
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  @sleep_ms 5_300

  def delegate_reply(conn, ref, adopter),
    do: FakeConnection.delegate_reply(conn, ref, adopter)

  def reply(conn, ref, result), do: FakeConnection.reply(conn, ref, result)

  def notify(conn, "_raxol/session.record" = method, params) do
    Process.sleep(@sleep_ms)
    FakeConnection.notify(conn, method, params)
  end

  def notify(conn, method, params),
    do: FakeConnection.notify(conn, method, params)
end

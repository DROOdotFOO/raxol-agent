defmodule Raxol.AgentClientProtocol.Ext.ReattachEdgeCasesTest do
  @moduledoc """
  Reattach/journal edge cases: slow replays, far-future
  expiries, injected authorizers, partial contexts and cancelled requests.
  """

  use Raxol.AgentClientProtocol.Test.ReattachCase, async: false

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.Journal.Mem
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Ext.Reattach
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  import ExUnit.CaptureLog

  # The synchronous replay runs inside `GenServer.call(sub,
  # :run)`; on the default 5s timeout a history slower than 5s crashes the attach
  # handler. The subscriber owns its own expiry timer, so the call must be
  # `:infinity`.
  describe "large-history replay must not time out the run call" do
    @tag timeout: 20_000
    test "a replay slower than the default 5s call window does NOT crash attach" do
      {sid, j, _w} = start_writer()
      {:ok, conn} = FakeConnection.start_link()

      assert :deferred =
               Reattach.attach(%{
                 conn: conn,
                 conn_mod: Raxol.AgentClientProtocol.Test.SlowRecordConn,
                 session_id: sid,
                 reply_ref: make_ref(),
                 journal: {Mem, j},
                 authorize: granting()
               })

      assert {:reply, _ref, {:ok, _}} = reply_entry(conn)
    end
  end

  # `Process.send_after/3` raises above the OTP timer ceiling, so
  # a grant with a far-future `exp` crashes the subscriber right after it replied.
  # The arm must clamp the delay.
  describe "a far-future grant.expires_at does not crash the subscriber" do
    test "an exp past the timer ceiling arms without ArgumentError; the sub lives" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      now = System.os_time(:second)
      far = now + 1_000_000_000_000

      {conn, ref, sub, res} =
        attach(sid, j, %{
          authorize: fn ctx ->
            {:ok, grant(%{session_id: ctx.session_id, expires_at: far})}
          end,
          now: now
        })

      assert res == :deferred
      assert is_pid(sub) and Process.alive?(sub)
      _ = sync(sub)
      assert {:reply, ^ref, {:ok, _}} = reply_entry(conn)
      refute_receive {:DOWN, _, :process, ^sub, _}, 100
    end
  end

  # The injected `:authorize` seam admits ANY `{:ok, map}` —
  # including an empty map — bypassing the Grant contract. `run_authorize` must
  # re-assert it.
  describe "an injected authorize returning a non-Grant is denied" do
    test "{:ok, %{}} (empty map) denies: -32000, NO registration, NO history" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      res =
        Reattach.attach(%{
          conn: conn,
          conn_mod: FakeConnection,
          session_id: sid,
          reply_ref: make_ref(),
          journal: {Mem, j},
          authorize: fn _ctx -> {:ok, %{}} end
        })

      assert {:error, %Error{code: -32_000, data: nil}} = res
      assert FakeConnection.log(conn) == []
      assert %{subscribers: subs} = :sys.get_state(Writer.whereis(sid))
      assert subs == %{}
    end

    test "a grant whose session_id mismatches ctx denies (session-id match [G5:X1])" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      res =
        Reattach.attach(%{
          conn: conn,
          conn_mod: FakeConnection,
          session_id: sid,
          reply_ref: make_ref(),
          journal: {Mem, j},
          authorize: fn ctx ->
            {:ok, grant(%{session_id: "other-" <> ctx.session_id})}
          end
        })

      assert {:error, %Error{code: -32_000}} = res
      assert FakeConnection.log(conn) == []
    end

    test "a grant missing actor \"id\" denies; a well-formed loose grant still admits" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])

      {conn_d, _rd, _sub_d, res_d} =
        attach(sid, j, %{authorize: fn _ctx -> {:ok, grant(%{actor: %{}})} end})

      assert {:error, %Error{code: -32_000}} = res_d
      assert FakeConnection.log(conn_d) == []

      {conn_g, ref_g, sub_g, res_g} =
        attach(sid, j, %{authorize: fn _ctx -> {:ok, grant()} end})

      assert res_g == :deferred
      _ = sync(sub_g)
      assert {:reply, ^ref_g, {:ok, _}} = reply_entry(conn_g)
    end
  end

  # The unsupervised fallback links the Subscriber to the
  # ephemeral caller; a :normal caller exit never signals the link, leaking the
  # Subscriber past its connection. It must tie its lifetime to the conn.
  describe "the fallback subscriber dies with its connection" do
    test "killing the connection stops an unsupervised fallback subscriber" do
      {sid, j, w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      assert :deferred =
               Reattach.attach(%{
                 conn: conn,
                 conn_mod: FakeConnection,
                 session_id: sid,
                 reply_ref: make_ref(),
                 journal: {Mem, j},
                 authorize: granting()
               })

      [sub] =
        for {_ref, %{pid: pid}} <- :sys.get_state(w).subscribers, do: pid

      mon = Process.monitor(sub)
      # Unlink first: FakeConnection.start_link/0 links conn to THIS test process,
      # so a raw :kill would also take the test down. Unlinking isolates the crash
      # to conn — the subscriber's conn-monitor then fires and stops it.
      Process.unlink(conn)
      Process.exit(conn, :kill)
      assert_receive {:DOWN, ^mon, :process, ^sub, _}, 500
      refute Process.alive?(sub)
    end
  end

  # A partial injected `:ctx` (missing :session_id / :surface)
  # must not crash `emit_denied` with a KeyError on the deny path.
  describe "deny path tolerates a partial injected ctx" do
    test "a denied attach with a partial ctx returns the deny envelope, no KeyError" do
      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      {:ok, conn} = FakeConnection.start_link()

      res =
        Reattach.attach(%{
          conn: conn,
          conn_mod: FakeConnection,
          session_id: sid,
          reply_ref: make_ref(),
          journal: {Mem, j},
          ctx: %{transport: nil},
          authorize: fn _ctx -> {:denied, :nope} end
        })

      assert {:error, %Error{code: -32_000}} = res
    end
  end

  describe "attach with neither :authorize nor :policy" do
    test "uses the configured :attach_policy, else LocalNode, and logs no error" do
      start_supervised!(
        {Task.Supervisor, name: Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor}
      )

      {sid, j, _w} = start_writer([{"session_update", %{"i" => 1}, "agent"}])
      local = %{authorize: nil, transport: %{kind: :process, peer: self()}}
      prev = Application.fetch_env(:raxol_agent_client_protocol, :attach_policy)

      on_exit(fn ->
        case prev do
          {:ok, policy} ->
            Application.put_env(:raxol_agent_client_protocol, :attach_policy, policy)

          :error ->
            Application.delete_env(:raxol_agent_client_protocol, :attach_policy)
        end
      end)

      Application.put_env(:raxol_agent_client_protocol, :attach_policy, __MODULE__.DenyAll)

      log =
        capture_log(fn ->
          {conn, _ref, _sub, res} = attach(sid, j, local)
          assert {:error, %Error{code: -32_000}} = res
          assert FakeConnection.log(conn) == []
        end)

      assert log =~ "acp attach denied: :policy_error"
      refute log =~ "[error]"

      Application.delete_env(:raxol_agent_client_protocol, :attach_policy)

      log =
        capture_log(fn ->
          {conn, ref, sub, res} = attach(sid, j, local)
          assert res == :deferred
          _ = sync(sub)
          assert {:reply, ^ref, {:ok, _}} = reply_entry(conn)
        end)

      refute log =~ "[error]"
    end
  end

  defmodule DenyAll do
    @moduledoc false
    @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy

    @impl true
    def authorize_attach(_ctx), do: {:error, :denied_by_test}
  end

  describe "attach on a request the peer already cancelled" do
    test "stops the subscriber and sends nothing" do
      {sid, j, _w} = start_writer([])
      {:ok, conn} = FakeConnection.start_link(delegate_result: {:error, :cancelled})
      test = self()

      result =
        Reattach.attach(%{
          conn: conn,
          conn_mod: FakeConnection,
          session_id: sid,
          reply_ref: make_ref(),
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
        })

      assert {:error, %Error{code: -32_800}} = result
      assert_receive {:sub, sub}
      refute Process.alive?(sub)
      assert FakeConnection.count(conn, :notify) == 0
      assert FakeConnection.count(conn, :reply) == 0
    end
  end
end

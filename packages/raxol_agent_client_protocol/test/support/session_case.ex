defmodule Raxol.AgentClientProtocol.Test.SessionCase do
  @moduledoc """
  Shared fixtures for the Session suites (`session_*_test.exs`): a Session
  started directly against `FakeConnection`, scripted turn runners and
  wait helpers. `use` it in place of `ExUnit.Case`; it arms the invariant
  sentinel and starts the session registry, a task supervisor (`ctx.task_sup`)
  and a session supervisor (`ctx.session_sup`).
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Emitter
  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.FakeConnection

  using do
    quote do
      use Raxol.AgentClientProtocol.Test.InvariantSentinel

      import Raxol.AgentClientProtocol.Test.SessionCase
    end
  end

  setup do
    start_supervised!(SessionSup.registry_child_spec())
    task_sup = start_supervised!({Task.Supervisor, []})
    session_sup = start_supervised!({SessionSup, []})
    {:ok, task_sup: task_sup, session_sup: session_sup}
  end

  @spec new_conn(keyword()) :: pid()
  def new_conn(opts \\ []),
    do: start_supervised!({FakeConnection, opts}, id: {:conn, make_ref()})

  # Start a Session directly (registered on {conn, sid} via its :via name).
  @spec start_session(map(), pid(), keyword()) :: {pid(), String.t()}
  def start_session(ctx, conn, overrides) do
    sid = Keyword.get_lazy(overrides, :session_id, fn -> "sess-" <> hex() end)

    opts =
      [
        session_id: sid,
        conn: conn,
        conn_mod: FakeConnection,
        task_sup: ctx.task_sup,
        turn_runner: Keyword.get(overrides, :turn_runner, runner_ends(:end_turn)),
        mode_state: Keyword.get(overrides, :mode_state),
        emitter: Keyword.get(overrides, :emitter, Emitter.Direct),
        config: Keyword.get(overrides, :config, %{cancel_backstop_ms: 50})
      ]

    # sessions are :temporary by design (§1.2) — a killed session must not restart
    pid =
      start_supervised!(%{
        id: {:sess, sid, make_ref()},
        start: {Session, :start_link, [opts]},
        restart: :temporary
      })

    {pid, sid}
  end

  @spec hex() :: String.t()
  def hex, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # A prompt turn: mints a reply_ref, drives begin_prompt, returns the reply_ref.
  @spec begin(pid(), non_neg_integer(), term()) :: {term(), reference()}
  def begin(session, rx_seq \\ 1, req \\ :prompt_req) do
    reply_ref = make_ref()
    res = Session.begin_prompt(session, req, reply_ref, rx_seq)
    {res, reply_ref}
  end

  @spec wait_until((-> as_boolean(term())), timeout()) :: :ok
  def wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  @doc false
  @spec do_wait_until((-> as_boolean(term())), integer()) :: :ok
  def do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end

  @spec wait_for_reply(pid(), timeout()) :: tuple()
  def wait_for_reply(conn, timeout \\ 2_000) do
    wait_until(fn -> FakeConnection.count(conn, :reply) >= 1 end, timeout)
    [reply | _] = FakeConnection.entries(conn, :reply)
    reply
  end

  @spec turn_state(pid()) :: term()
  def turn_state(session), do: :sys.get_state(session).turn

  # -- turn runners -----------------------------------------------------------

  @spec runner_ends(term()) :: (pid(), term() -> {:stop, term()})
  def runner_ends(reason), do: fn _s, _req -> {:stop, reason} end

  @spec runner_posts_then_ends([term()]) :: (pid(), term() -> {:stop, :end_turn})
  def runner_posts_then_ends(notifs) do
    fn s, _req ->
      Enum.each(notifs, fn n -> Session.post_update(s, n) end)
      {:stop, :end_turn}
    end
  end

  @spec mode_notif(String.t()) :: SessionNotification.t()
  def mode_notif(sid),
    do: SessionNotification.new(sid, {:current_mode_update, CurrentModeUpdate.new("code")})
end

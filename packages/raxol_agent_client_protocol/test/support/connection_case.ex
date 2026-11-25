defmodule Raxol.AgentClientProtocol.Test.ConnectionCase do
  @moduledoc """
  Shared fixtures for the Connection suites (`connection_*_test.exs`).

  `ScriptedPeer` plays the peer with raw wire maps; the `ScriptAgent` and
  `ScriptClient` handlers ask the test process what to do via
  `Rendezvous.invoke/3`, so each test scripts its handler behaviour inline.
  `use` it in place of `ExUnit.Case`: it arms the invariant sentinel, tags
  the module `:capture_log` and imports the helpers below.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Test.ConnectionCase.ScriptAgent
  alias Raxol.AgentClientProtocol.Test.ConnectionCase.ScriptClient
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  using do
    quote do
      use Raxol.AgentClientProtocol.Test.InvariantSentinel

      import Raxol.AgentClientProtocol.Test.ConnectionCase

      alias Raxol.AgentClientProtocol.Test.ConnectionCase.ScriptAgent
      alias Raxol.AgentClientProtocol.Test.ConnectionCase.ScriptClient

      @moduletag :capture_log
    end
  end

  # `use GenServer`'s default `child_spec/1` omits `:restart`, which a plain
  # `Supervisor`/`start_supervised!` then defaults to `:permanent` -- but
  # IC-8 pins Connection as `:temporary` under its real ConnectionSupervisor.
  # Several tests here deliberately drive Connection to `{:stop, :normal,
  # _}` (transport-down paths); without an explicit `:temporary` override,
  # ExUnit's own per-test supervisor would restart it with the SAME (by then
  # stale) init args, racing a later test's process churn. Always pass the
  # design-correct restart strategy explicitly.
  @spec connection_child_spec(keyword()) :: Supervisor.child_spec()
  def connection_child_spec(opts) do
    %{id: Connection, start: {Connection, :start_link, [opts]}, restart: :temporary}
  end

  @spec start_agent_conn(term()) :: %{
          conn: pid(),
          peer: term(),
          conn_handle: term(),
          task_sup: pid()
        }
  def start_agent_conn(handler_arg \\ nil) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        connection_child_spec(
          role: :agent,
          transport: {Paired, conn_handle},
          handler: ScriptAgent,
          handler_arg: handler_arg || self(),
          task_sup: task_sup
        )
      )

    %{conn: conn, peer: peer, conn_handle: conn_handle, task_sup: task_sup}
  end

  @spec start_client_conn(term()) :: %{
          conn: pid(),
          peer: term(),
          conn_handle: term(),
          task_sup: pid()
        }
  def start_client_conn(handler_arg \\ nil) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        connection_child_spec(
          role: :client,
          transport: {Paired, conn_handle},
          handler: ScriptClient,
          handler_arg: handler_arg || self(),
          task_sup: task_sup
        )
      )

    %{conn: conn, peer: peer, conn_handle: conn_handle, task_sup: task_sup}
  end

  # Waits for the next `{:handler_invoke, name, params, ctx, task_pid, ref}`
  # matching `name`, hands the task the closure to run, and returns
  # everything a test might need to script or observe the dispatch.
  # 2s default (not assert_receive's 100ms, nor a tight 500ms): the dispatch
  # is real cross-process work and some callers (e.g. Inv-7) drive it only
  # after a few hundred preceding wire messages, so under a loaded async suite
  # the invoke can legitimately land later than a tight bound. Generous here is
  # free -- assert_receive returns the instant the message arrives; the timeout
  # only bites when it is genuinely absent, still far below any real hang.
  @spec handle_next_invoke(atom(), (term(), Connection.Ctx.t() -> term()), timeout()) ::
          %{params: term(), ctx: Connection.Ctx.t(), task_pid: pid()}
  def handle_next_invoke(name, fun, timeout \\ 2_000) do
    assert_receive {:handler_invoke, ^name, params, ctx, task_pid, ref}, timeout
    send(task_pid, {:handler_run, ref, fun})
    %{params: params, ctx: ctx, task_pid: task_pid}
  end

  # Drives a fresh agent-role Connection through the `initialize` handshake
  # (design §7.2) using the given wire id, returning the dispatch `ctx`
  # (useful for asserting `caps` snapshot equality later, Inv-11).
  @spec complete_handshake(term(), integer() | String.t()) :: Connection.Ctx.t()
  def complete_handshake(peer, id \\ 1) do
    ScriptedPeer.send_request(peer, id, "initialize", %{"protocolVersion" => 1})

    %{ctx: ctx} =
      handle_next_invoke(:initialize, fn _req, _ctx -> {:ok, InitializeResponse.new(1)} end)

    frame = ScriptedPeer.recv(peer)
    assert frame["id"] == id
    assert frame["result"]["protocolVersion"] == 1
    ctx
  end

  @spec new_session_params(String.t()) :: map()
  def new_session_params(cwd \\ "/tmp"), do: %{"cwd" => cwd}

  @spec prompt_params(String.t()) :: map()
  def prompt_params(session_id) do
    %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => "hi"}]}
  end

  @spec rand_hex() :: String.t()
  def rand_hex, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  @spec session_update_params(String.t(), String.t()) :: map()
  def session_update_params(session_id, mode_id \\ "m1") do
    %{
      "sessionId" => session_id,
      "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
    }
  end

  # Design-endorsed technique (Inv-2/3/11/17 all say "Test: :sys.get_state
  # after each path") for assertions that must observe a transition whose
  # only externally-visible signal is internal-state settling (e.g. a cast
  # landing, a task being reaped) rather than a wire frame. Every individual
  # sleep is small (5ms); the bound (40 tries) caps total wait at 200ms.
  @spec wait_until((-> as_boolean(term())), non_neg_integer()) :: :ok
  def wait_until(fun, tries \\ 40) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        flunk("condition not met within the wait budget")

      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end
end

defmodule Raxol.AgentClientProtocol.Test.ConnectionCase.Rendezvous do
  @moduledoc false

  @spec invoke(atom(), term(), Raxol.AgentClientProtocol.Connection.Ctx.t()) :: term()
  def invoke(name, params, ctx) do
    test_pid = ctx.handler_state
    ref = make_ref()
    send(test_pid, {:handler_invoke, name, params, ctx, self(), ref})

    receive do
      {:handler_run, ^ref, fun} -> fun.(params, ctx)
    end
  end
end

defmodule Raxol.AgentClientProtocol.Test.ConnectionCase.ScriptAgent do
  @moduledoc false
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.Test.ConnectionCase.Rendezvous

  @impl true
  def initialize(req, ctx), do: Rendezvous.invoke(:initialize, req, ctx)

  @impl true
  def new_session(req, ctx), do: Rendezvous.invoke(:new_session, req, ctx)

  @impl true
  def prompt(req, ctx), do: Rendezvous.invoke(:prompt, req, ctx)

  @impl true
  def handle_ext_request(wire, params, ctx),
    do: Rendezvous.invoke(:ext_request, {wire, params}, ctx)
end

defmodule Raxol.AgentClientProtocol.Test.ConnectionCase.ScriptClient do
  @moduledoc false
  use Raxol.AgentClientProtocol.Client

  alias Raxol.AgentClientProtocol.Test.ConnectionCase.Rendezvous

  @impl true
  def session_update(note, ctx), do: Rendezvous.invoke(:session_update, note, ctx)

  @impl true
  def read_text_file(req, ctx), do: Rendezvous.invoke(:read_text_file, req, ctx)
end

defmodule Raxol.Agent.Session.Companions do
  @moduledoc false
  # The two processes a session runs beside: its `Raxol.Core.Runtime.Lifecycle`
  # (the agent's TEA runtime) and its `Raxol.Agent.EmitBridge` (the journal
  # sink). A standalone session starts and stops them itself; under
  # `Raxol.Agent.Session.Supervisor` they are supervised siblings and the
  # session only looks them up.

  alias Raxol.Agent.CommandHook
  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Session.Registration
  alias Raxol.Core.Defaults
  alias Raxol.Core.Runtime.Lifecycle, as: Runtime

  @dynsup Raxol.Agent.DynSup
  @registry Raxol.Agent.Registry

  # Bounds how long the parent supervisor waits on the lifecycle before a
  # brutal kill. The runtime does not trap exits, so it dies on `:shutdown`
  # without draining; `Session.Supervisor.stop_session/1` flushes the journal
  # tail before tearing the tree down.
  @doc "Child spec for the tree-owned lifecycle (between bridge and session)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: :lifecycle,
      start: {__MODULE__, :start_supervised, [opts]},
      restart: :permanent,
      shutdown: Defaults.shutdown_timeout_ms()
    }
  end

  @doc "Start the lifecycle linked to its supervisor, after its old name clears."
  @spec start_supervised(keyword()) :: GenServer.on_start()
  def start_supervised(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    id = Keyword.fetch!(opts, :id)
    session_id = Keyword.fetch!(opts, :session_id)

    Registration.await_free({:lifecycle, session_id})
    Runtime.start_link(app_module, runtime_opts(app_module, id, session_id))
  end

  @doc """
  Start the lifecycle for a standalone session, unlinked so its crash reaches
  the session as a monitor `:DOWN`. A lifecycle a brutally killed predecessor
  left under the same session id is reattached.
  """
  @spec start_owned(module(), term(), String.t()) :: pid()
  def start_owned(app_module, id, session_id) do
    case Runtime.start_link(app_module, runtime_opts(app_module, id, session_id)) do
      {:ok, pid} ->
        Process.unlink(pid)
        pid

      {:error, {:already_started, pid}} ->
        pid
    end
  end

  @doc "The tree-owned lifecycle of `session_id`."
  @spec lookup(String.t()) :: pid() | nil
  def lookup(session_id), do: Registration.lookup({:lifecycle, session_id})

  @doc """
  Stop the lifecycle and wait until it is dead, so its name is free for a
  restart. Waits one second past the runtime's own shutdown budget, then
  kills it: a restart that reattached to a dying runtime would lose every
  message sent to it.
  """
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Runtime.stop(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        stop_budget_ms() ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
      end
    end

    :ok
  end

  @doc "How long `stop/1` may block. A parent's shutdown budget must exceed it."
  @spec stop_budget_ms() :: pos_integer()
  def stop_budget_ms, do: Defaults.shutdown_timeout_ms() + 1_000

  @doc "The lifecycle's dispatcher pid, or nil when it is down."
  @spec dispatcher(pid() | nil) :: pid() | nil
  def dispatcher(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      %{dispatcher_pid: dispatcher} = GenServer.call(pid, :get_full_state)
      dispatcher
    end
  catch
    :exit, _ -> nil
  end

  def dispatcher(_pid), do: nil

  @doc """
  Start the session's emit bridge, under `Raxol.Agent.DynSup` when it runs
  and unlinked otherwise, so a bridge crash never takes the session down.

  The bridge registers as `{:emit_bridge, session_id}`. A bridge a crashed
  session left running is adopted rather than duplicated. Returns nil when
  no bridge starts.
  """
  @spec start_bridge(String.t(), keyword()) :: pid() | nil
  def start_bridge(session_id, extra_opts) do
    opts = [session_id: session_id] ++ extra_opts ++ bridge_name(session_id)

    with sup when is_pid(sup) <- Process.whereis(@dynsup),
         {:ok, pid} <- start_bridge_child(opts) do
      pid
    else
      _ -> start_bridge_unlinked(opts)
    end
  end

  defp start_bridge_child(opts) do
    case DynamicSupervisor.start_child(@dynsup, {EmitBridge, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} -> :error
    end
  end

  defp start_bridge_unlinked(opts) do
    case EmitBridge.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)
        pid

      {:error, {:already_started, pid}} ->
        pid

      _ ->
        nil
    end
  end

  defp bridge_name(session_id) do
    if Process.whereis(@registry),
      do: [name: {:via, Registry, {@registry, {:emit_bridge, session_id}}}],
      else: []
  end

  @doc "The tree-owned emit bridge of `session_id`."
  @spec lookup_bridge(String.t()) :: pid() | nil
  def lookup_bridge(session_id), do: Registration.lookup({:emit_bridge, session_id})

  @doc """
  Stop a session-owned bridge after draining its mailbox, so the durable
  events the lifecycle published while stopping reach the journal. Under
  DynSup the bridge is a permanent child and must be terminated there.
  """
  @spec stop_bridge(pid() | nil) :: :ok
  def stop_bridge(nil), do: :ok

  def stop_bridge(pid) do
    if Process.alive?(pid) do
      drain_mailbox(pid)

      with sup when is_pid(sup) <- Process.whereis(@dynsup),
           :ok <- DynamicSupervisor.terminate_child(@dynsup, pid) do
        :ok
      else
        _ -> GenServer.stop(pid, :normal, 1_000)
      end
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # A synchronous system call returns only after every earlier message is
  # handled.
  defp drain_mailbox(pid) do
    _ = :sys.get_state(pid, Defaults.shutdown_timeout_ms())
    :ok
  catch
    :exit, _ -> :ok
  end

  defp runtime_opts(app_module, id, session_id) do
    [
      environment: :agent,
      width: Defaults.terminal_width(),
      height: Defaults.terminal_height(),
      # A Registry key, not a per-session atom: atoms are never collected.
      name: {:via, Registry, {@registry, {:lifecycle, session_id}}},
      command_interceptor: command_interceptor(app_module, id),
      session_id: session_id
    ]
  end

  # Runs the agent's permission/sandbox/audit hooks before any Shell, Async
  # or SendAgent directive. nil when the agent declares no hooks.
  defp command_interceptor(app_module, id) do
    case Raxol.Agent.effective_hooks(app_module) do
      [] ->
        nil

      hooks ->
        context = %{agent_id: id, agent_module: app_module}
        &CommandHook.wrap_commands(&1, hooks, context)
    end
  end
end

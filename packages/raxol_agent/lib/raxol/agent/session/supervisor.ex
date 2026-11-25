defmodule Raxol.Agent.Session.Supervisor do
  @moduledoc """
  One supervised OTP subtree per harness session, plus the `session_id -> pid`
  registry.

  ## Tree shape

  `:rest_for_one`, children in dependency order:

    1. `Raxol.Agent.EmitBridge` -- the per-session sink: owns the journal handle
       and the EmitBus subscription.
    2. `Raxol.Core.Runtime.Lifecycle` -- the per-session TEA runtime, registered
       under `{:lifecycle, session_id}`. It starts after the sink is subscribed.
       As a supervised child it is torn down with the subtree and started fresh
       on restart, so it can neither leak nor be reattached to a dead session.
    3. `Raxol.Agent.Session` -- the thin forwarder, started with
       `start_emit_bridge: false` and `manage_lifecycle: false`.

  So a **bridge crash** restarts bridge, lifecycle and session in order (a fresh
  lifecycle; the restarted bridge reopens the journal at its on-disk offset), and
  a **session crash** restarts only the session, which re-resolves the same
  running lifecycle (model preserved).

  ## Registry keys (`Raxol.Agent.Registry`)

    * `{:session_supervisor, session_id}` -> this subtree; value is the `:owner`
      (`nil` without one)
    * `{:session, session_id}` -> the `Raxol.Agent.Session` (supervised or
      standalone, so `whereis/1` resolves either)
    * `{:emit_bridge, session_id}` -> the sink

  A second `start_session/2` with the same `session_id` returns
  `{:error, {:already_started, pid}}`.

  ## Placement

  Subtrees run under `Raxol.Agent.DynSup`, crash-isolated from each other and the
  caller. `start_session/2` requires `Raxol.Agent.Registry` and
  `Raxol.Agent.DynSup` (boot `Raxol.Agent.Supervisor`, or start both in tests).
  The journal `FileStore.Writer` keeps a `:global` name keyed by journal
  directory, enforcing one writer per directory across sessions and nodes.
  """

  use Supervisor

  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.Session
  alias Raxol.Core.Defaults

  @registry Raxol.Agent.Registry
  @dynsup Raxol.Agent.DynSup

  @doc """
  Start a session as one supervised subtree under `Raxol.Agent.DynSup`.

  Returns `{:ok, pid}` where `pid` is the subtree supervisor (resolve the
  session process itself with `whereis/1`). A second call with the same
  `session_id` returns `{:error, {:already_started, pid}}`.

  Options (all `Raxol.Agent.Session` options are accepted and forwarded):

    * `:session_id` — the harness session key (default: derived from `:id`
      or the app module, filename-safe + unique suffix)
    * `:id` — the agent id for `Raxol.Agent.Registry` discovery (default:
      `{:harness_session, session_id}`)
    * `:journal` / `:journal_opts` — forwarded to the tree-owned
      `Raxol.Agent.EmitBridge`
    * `:journal_required` — `true` for a session that must not run
      unjournaled: the bridge opens the journal in its `init` (in the session
      tree, so the Writer is linked to the bridge and not to the caller),
      private and locked, and when it cannot (a live lock holder, no lock, a
      journal bound to another `:cwd` or `:title` in `:journal_opts`) nothing
      is started and this returns `{:error, reason}` with the bridge's stop
      reason (see "A required journal" in `Raxol.Agent.EmitBridge`)
    * `:owner` — any term, kept as the value of the tree's registry entry
      (`{:session_supervisor, session_id}`) for as long as the tree runs, so
      whoever started the session can recognise it later (see `owner/1`)
  """
  @spec start_session(module(), keyword()) ::
          {:ok, pid()} | {:error, {:already_started, pid()} | term()}
  def start_session(app_module, opts \\ []) when is_atom(app_module) do
    with :ok <- ensure_infrastructure() do
      opts = normalize_opts(app_module, opts)

      @dynsup
      |> DynamicSupervisor.start_child(tree_spec(opts))
      |> journal_refusal(Keyword.get(opts, :journal_required, false))
    end
  end

  # A required journal's refusal is the reason the caller asked for, not the
  # supervisor's wrapping of a child that did not start.
  defp journal_refusal(
         {:error, {:shutdown, {:failed_to_start_child, :emit_bridge, reason}}},
         true
       ),
       do: {:error, reason}

  defp journal_refusal(result, _required?), do: result

  @doc """
  Stop a session's whole subtree (session first, then the sink — the reverse
  of start order — so the bridge's `terminate/2` flushes and closes the
  journal handle last). Also stops bare `Raxol.Agent.Session.start_link`
  sessions that registered under `{:session, session_id}`.

  ## Journal-tail completeness guarantee (graceful stop)

  Before tearing the tree down, `stop_session/1` drains the durable tail so a
  graceful stop never silently truncates the journal. The runtime `Lifecycle`
  does NOT trap exits, so a plain subtree teardown would kill the dispatcher
  (and the events queued in its mailbox) with no drain. Instead we flush in
  dependency order using synchronous FIFO barriers — a `:sys.get_state/2` call
  returns only after every message enqueued before it has been handled:

    1. barrier on the **session** — `send_message` is a cast the session forwards
       (also a cast) to the dispatcher, so this drains queued inbound messages
       out of the session's mailbox into the dispatcher's first;
    2. barrier on the **dispatcher** — it processes its whole mailbox, publishing
       each queued durable event to `EmitBus`, which `send`s it (synchronously)
       into the bridge's mailbox;
    3. barrier on the **bridge** — it processes its whole mailbox, `append`ing
       each durable event to the journal `Writer` (a synchronous call).

  Neither barrier stops a process, so no `:rest_for_one` restart is triggered.
  Only then do we tear the subtree down; the journal `Writer` (which traps exits)
  datasyncs and closes in its own `terminate/2`.

  GUARANTEED: every durable event enqueued to the dispatcher at the moment the
  drain begins is appended to the journal and datasynced before teardown.
  NOT guaranteed: events emitted *concurrently* by a still-running async turn
  after the barriers pass — they race the teardown. For the harness's
  synchronous one-message-one-turn model, once inbound `send_message`s stop the
  tail is captured in full. The drain is bounded (best-effort) and never blocks
  teardown on a slow/dead process.
  """
  @spec stop_session(term()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case lookup({:session_supervisor, session_id}) do
      pid when is_pid(pid) ->
        drain_durable_tail(session_id)
        stop_tree(pid)

      nil ->
        # Standalone sessions drain themselves: `Session.terminate/2` runs
        # `stop_lifecycle_sync` (drains the dispatcher) then stops the bridge
        # (which flushes the journal), so no extra drain is needed here.
        stop_standalone(session_id)
    end
  end

  # Flush dispatcher -> bridge -> journal via FIFO barriers so a graceful stop
  # captures the full durable tail before the tree is torn down. See the
  # `stop_session/1` doc for the completeness guarantee. Best-effort and bounded:
  # any missing/slow/dead process just short-circuits — teardown proceeds either
  # way, and a hard teardown is still safe (the Writer datasyncs on its own exit).
  defp drain_durable_tail(session_id) do
    flush_barrier(lookup({:session, session_id}))
    flush_barrier(dispatcher_for(session_id))
    flush_barrier(lookup({:emit_bridge, session_id}))
    :ok
  end

  defp dispatcher_for(session_id) do
    with pid when is_pid(pid) <- lookup({:lifecycle, session_id}),
         %{dispatcher_pid: dispatcher} <-
           GenServer.call(pid, :get_full_state, drain_timeout()) do
      dispatcher
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # A synchronous system message is a FIFO barrier: it returns only after every
  # message enqueued before it has been handled, draining the mailbox into the
  # process's side effects (dispatcher: publish to EmitBus; bridge: append to
  # journal) WITHOUT stopping it (so no `:rest_for_one` restart fires).
  defp flush_barrier(pid) when is_pid(pid) do
    _ = :sys.get_state(pid, drain_timeout())
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp flush_barrier(_), do: :ok

  defp drain_timeout, do: Defaults.shutdown_timeout_ms()

  @doc """
  Resolve `session_id` to the live `Raxol.Agent.Session` pid, or `nil`.
  """
  @spec whereis(term()) :: pid() | nil
  def whereis(session_id), do: lookup({:session, session_id})

  @doc """
  The `:owner` the tree running under `session_id` was started with:
  `{:ok, owner}` (`nil` when it was given none), or `:error` when no tree
  runs under that id.
  """
  @spec owner(term()) :: {:ok, term()} | :error
  def owner(session_id) do
    case live(Registry.lookup(@registry, {:session_supervisor, session_id})) do
      [{_pid, owner}] -> {:ok, owner}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Every running session tree, as `{session_id, owner}`."
  @spec owners() :: [{term(), term()}]
  def owners do
    @registry
    |> Registry.select([
      {{{:session_supervisor, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", {{:"$1", :"$3"}}}}]}
    ])
    |> live()
    |> Enum.map(fn {_pid, entry} -> entry end)
  rescue
    ArgumentError -> []
  end

  @doc """
  All live sessions as `{session_id, session_pid}` — supervised subtrees and
  standalone `Session.start_link` sessions alike.
  """
  @spec list_sessions() :: [{term(), pid()}]
  def list_sessions do
    @registry
    |> Registry.select([{{{:session, :"$1"}, :"$2", :_}, [], [{{:"$2", :"$1"}}]}])
    |> live()
    |> Enum.map(fn {pid, session_id} -> {session_id, pid} end)
  rescue
    # Registry not running — no sessions.
    ArgumentError -> []
  end

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    Supervisor.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {@registry, {:session_supervisor, session_id}, Keyword.get(opts, :owner)}}
    )
  end

  @impl Supervisor
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    bridge_opts =
      [
        session_id: session_id,
        name: {:via, Registry, {@registry, {:emit_bridge, session_id}}}
      ]
      |> copy_opt(:journal, opts)
      |> copy_opt(:journal_opts, opts)
      |> copy_opt(:journal_required, opts)

    # The tree owns the sink AND the lifecycle; the session starts (and stops)
    # neither — it only looks them up and forwards to the runtime's dispatcher.
    session_opts =
      opts
      |> Keyword.put(:start_emit_bridge, false)
      |> Keyword.put(:manage_lifecycle, false)

    children = [
      %{
        id: :emit_bridge,
        start: {__MODULE__, :start_bridge, [session_id, bridge_opts]},
        restart: :permanent,
        shutdown: 5_000
      },
      Session.Companions.lifecycle_child_spec(opts),
      %{
        id: :session,
        start: {Session, :start_link, [session_opts]},
        restart: :permanent
      }
    ]

    # Each via-named child waits for its dead predecessor's Registry key to
    # clear before registering, so restarts do not race cleanup; this budget
    # only stops a crash loop.
    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 5
    )
  end

  @doc false
  # Start the per-session sink, waiting for a dead predecessor's
  # `{:emit_bridge, session_id}` via-name to clear first so a `:rest_for_one`
  # restart is deterministic rather than depending on winning the
  # race against Registry's async cleanup.
  @spec start_bridge(term(), keyword()) :: GenServer.on_start()
  def start_bridge(session_id, bridge_opts) do
    Session.Registration.await_free({:emit_bridge, session_id})
    EmitBridge.start_link(bridge_opts)
  end

  defp normalize_opts(app_module, opts) do
    session_id =
      Keyword.get(opts, :session_id) ||
        Session.Registration.derive_session_id(Keyword.get(opts, :id, app_module))

    opts
    |> Keyword.put(:app_module, app_module)
    |> Keyword.put(:session_id, session_id)
    |> Keyword.put_new(:id, {:harness_session, session_id})
  end

  defp tree_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :supervisor
    }
  end

  defp ensure_infrastructure do
    cond do
      is_nil(Process.whereis(@registry)) -> {:error, :registry_not_running}
      is_nil(Process.whereis(@dynsup)) -> {:error, :dynsup_not_running}
      true -> :ok
    end
  end

  defp lookup(key) do
    case live(Registry.lookup(@registry, key)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # The Registry drops a dead process's entries only when its partition
  # handles the exit, a moment after the process is gone, so a read in that
  # moment still returns them: a tree that `stop_session/1` just stopped would
  # read as running. Every read here keeps only processes that are alive.
  defp live(entries), do: Session.Registration.live(entries)

  # Prefer terminate_child (synchronous, removes the DynSup child); fall back
  # to a direct stop for a tree that was not started under DynSup.
  defp stop_tree(sup) do
    case Process.whereis(@dynsup) do
      nil ->
        stop_process(sup)

      _ ->
        case DynamicSupervisor.terminate_child(@dynsup, sup) do
          :ok -> :ok
          {:error, :not_found} -> stop_process(sup)
        end
    end
  end

  defp stop_standalone(session_id) do
    case lookup({:session, session_id}) do
      nil -> {:error, :not_found}
      pid -> stop_process(pid)
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp copy_opt(target, key, source) do
    case Keyword.fetch(source, key) do
      {:ok, value} -> Keyword.put(target, key, value)
      :error -> target
    end
  end
end

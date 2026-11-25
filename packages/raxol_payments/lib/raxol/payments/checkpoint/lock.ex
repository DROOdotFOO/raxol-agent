defmodule Raxol.Payments.Checkpoint.Lock do
  @moduledoc """
  A node-local mutual-exclusion lock per resource, for the read-modify-write
  steps of `Raxol.Payments.Checkpoint.ContextStore`.

  ## Why not `:global.trans/2`

  `:global` takes a lock by polling. A requester that finds it held sleeps a
  random backoff (up to 250ms at first, doubling to 8s) before trying again,
  even after the holder released long before. With a critical section of
  microseconds, sixteen concurrent `put_new/3` calls on one store took 1.4 to
  5.4s, and `:global.trans/2` also locks across every connected node for a
  table that is local to this one.

  Here waiters queue in order. The lock passes to the next one as soon as the
  holder finishes or exits, and nothing waits on a clock.

  ## Writers, and why the lock never has two

  `with_lock/2` runs `fun` in a writer process, not in the caller. The writer
  takes the lock, runs `fun`, hands the result back, and exits; its exit
  releases the lock. Writers run under `Raxol.Payments.Checkpoint.Lock.Supervisor`
  (in the `raxol_payments` application tree), after the lock process and
  `:rest_for_one`. If the lock process exits, the supervisor kills every
  writer and waits for each to be gone before it starts a new lock. A new lock
  starts empty, but no writer from before it is still running, so it can never
  admit a second writer next to one the old lock admitted.

  The lock fails closed:

  * A writer killed that way does not finish `fun`; its caller exits with
    `{:lock_lost, resource}` instead of carrying on as if the write landed.
  * So does a caller whose writer could not start: the lock is not running,
    or is in the middle of a restart.
  * A caller that dies while its writer waits or holds takes the writer down
    with it (the lock process monitors callers), as if `fun` had run in the
    caller.

  A waiter that dies in the queue is skipped when its turn comes.
  """

  use GenServer

  @writers Raxol.Payments.Checkpoint.Lock.Writers

  @typep lock :: {pid(), reference(), :queue.queue(GenServer.from())}
  @typep state :: %{
           locks: %{optional(term()) => lock()},
           held: %{optional(reference()) => term()},
           callers: %{optional(reference()) => pid()},
           guards: %{optional(pid()) => reference()}
         }

  @doc false
  @spec writers() :: atom()
  def writers, do: @writers

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Run `fun` while holding the lock on `resource`, and return its result. An
  exception raised in `fun` is raised again here.

  `fun` runs in a writer process, so `self()` in it is not the caller's pid,
  and it must not depend on the caller's process state. Exits with
  `{:lock_lost, resource}` when the lock cannot be taken or is lost before
  `fun` finishes.

  Not reentrant: a `fun` that takes the lock on the resource it holds waits on
  itself forever.
  """
  @spec with_lock(term(), (-> result)) :: result when result: term()
  def with_lock(resource, fun) when is_function(fun, 0) do
    tag = make_ref()
    writer = start_writer(resource, fun, tag)
    ref = Process.monitor(writer)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        unwrap(result)

      {:DOWN, ^ref, :process, ^writer, _reason} ->
        exit({:lock_lost, resource})
    end
  end

  defp start_writer(resource, fun, tag) do
    caller = self()
    hold = fn -> hold(resource, fun, caller, tag) end

    case Task.Supervisor.start_child(@writers, hold, shutdown: :brutal_kill) do
      {:ok, writer} -> writer
      _not_started -> exit({:lock_lost, resource})
    end
  catch
    # The writer supervisor is not running: no lock, so no write.
    :exit, _reason -> exit({:lock_lost, resource})
  end

  # The writer: the lock's holder while it runs `fun`.
  defp hold(resource, fun, caller, tag) do
    acquire(resource, caller)

    result =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    send(caller, {tag, result})
  end

  # A lock that exits before granting ends the writer without running `fun`.
  defp acquire(resource, caller) do
    :ok = GenServer.call(__MODULE__, {:acquire, resource, caller}, :infinity)
  catch
    :exit, _reason -> exit(:shutdown)
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  @impl true
  @spec init(:ok) :: {:ok, state()}
  def init(:ok), do: {:ok, %{locks: %{}, held: %{}, callers: %{}, guards: %{}}}

  @impl true
  def handle_call({:acquire, resource, caller}, {writer, _tag} = from, state) do
    state = guard(state, writer, caller)

    case Map.fetch(state.locks, resource) do
      :error ->
        {:reply, :ok, grant(state, resource, writer, :queue.new())}

      {:ok, {holder, ref, waiting}} ->
        locks = Map.put(state.locks, resource, {holder, ref, :queue.in(from, waiting)})
        {:noreply, %{state | locks: locks}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      Map.has_key?(state.held, ref) -> {:noreply, released(state, ref, pid)}
      Map.has_key?(state.callers, ref) -> {:noreply, caller_down(state, ref)}
      true -> {:noreply, state}
    end
  end

  # A stray message must not take the lock, and every writer, down with it.
  def handle_info(_message, state), do: {:noreply, state}

  # The holder exited, having finished or not: pass the lock on.
  defp released(state, ref, holder) do
    {resource, held} = Map.pop(state.held, ref)
    {_holder, _ref, waiting} = Map.fetch!(state.locks, resource)
    hand_off(unguard(%{state | held: held}, holder), resource, waiting)
  end

  # A caller exited: its writer, holding or queued, goes too.
  defp caller_down(state, ref) do
    {writer, callers} = Map.pop(state.callers, ref)
    Process.exit(writer, :kill)
    %{state | callers: callers, guards: Map.delete(state.guards, writer)}
  end

  # Grant the lock to the next waiter, or free it. A waiter that has died is
  # still granted it: its monitor reports `:noproc` at once, and the DOWN
  # passes the lock on again.
  @spec hand_off(state(), term(), :queue.queue(GenServer.from())) :: state()
  defp hand_off(state, resource, waiting) do
    case :queue.out(waiting) do
      {:empty, _} ->
        %{state | locks: Map.delete(state.locks, resource)}

      {{:value, {writer, _tag} = from}, rest} ->
        state = grant(state, resource, writer, rest)
        GenServer.reply(from, :ok)
        state
    end
  end

  defp grant(state, resource, writer, waiting) do
    ref = Process.monitor(writer)

    %{
      state
      | locks: Map.put(state.locks, resource, {writer, ref, waiting}),
        held: Map.put(state.held, ref, resource)
    }
  end

  defp guard(state, writer, caller) do
    ref = Process.monitor(caller)

    %{
      state
      | callers: Map.put(state.callers, ref, writer),
        guards: Map.put(state.guards, writer, ref)
    }
  end

  defp unguard(state, writer) do
    case Map.pop(state.guards, writer) do
      {nil, _guards} ->
        state

      {ref, guards} ->
        Process.demonitor(ref, [:flush])
        %{state | guards: guards, callers: Map.delete(state.callers, ref)}
    end
  end
end

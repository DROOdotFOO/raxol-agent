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
  holder releases it or exits, and nothing waits on a clock.

  ## The lock process

  One process per node, registered under this module's name and started on
  first use without a link, so it outlives the caller that started it (the
  pattern of `Raxol.Agent.SpendGate.Reservations`). It monitors each holder: a
  holder that dies inside its critical section releases the lock. A waiter
  that dies in the queue is skipped when its turn comes.

  If the lock process itself exits, callers waiting on it exit too, rather
  than going ahead without the lock.
  """

  use GenServer

  @typep holder :: {pid(), reference(), :queue.queue(GenServer.from())}
  @typep state :: %{optional(term()) => holder()}

  @doc """
  Run `fun` while holding the lock on `resource`, and return its result.

  Not reentrant: a process that calls this again for a resource it already
  holds waits on itself forever.
  """
  @spec with_lock(term(), (-> result)) :: result when result: term()
  def with_lock(resource, fun) when is_function(fun, 0) do
    server = ensure_started()
    :ok = GenServer.call(server, {:acquire, resource}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release, resource, self()})
    end
  end

  @spec ensure_started() :: pid()
  defp ensure_started do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @impl true
  @spec init(:ok) :: {:ok, state()}
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, resource}, {pid, _tag} = from, state) do
    case Map.fetch(state, resource) do
      :error ->
        {:reply, :ok, Map.put(state, resource, {pid, Process.monitor(pid), :queue.new()})}

      {:ok, {holder, ref, waiting}} ->
        {:noreply, Map.put(state, resource, {holder, ref, :queue.in(from, waiting)})}
    end
  end

  @impl true
  def handle_cast({:release, resource, pid}, state) do
    case Map.fetch(state, resource) do
      {:ok, {^pid, ref, waiting}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, hand_off(state, resource, waiting)}

      _not_held_by_pid ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state, fn {_resource, {holder, r, _}} -> holder == pid and r == ref end) do
      {resource, {_holder, _ref, waiting}} -> {:noreply, hand_off(state, resource, waiting)}
      nil -> {:noreply, state}
    end
  end

  # A stray message must not take the lock, and every waiter, down with it.
  def handle_info(_message, state), do: {:noreply, state}

  # Grant the lock to the next waiter, or free it. A waiter that has died is
  # still granted it: its monitor reports `:noproc` at once, and the DOWN
  # passes the lock on again.
  @spec hand_off(state(), term(), :queue.queue(GenServer.from())) :: state()
  defp hand_off(state, resource, waiting) do
    case :queue.out(waiting) do
      {:empty, _} ->
        Map.delete(state, resource)

      {{:value, {pid, _tag} = from}, rest} ->
        ref = Process.monitor(pid)
        GenServer.reply(from, :ok)
        Map.put(state, resource, {pid, ref, rest})
    end
  end
end

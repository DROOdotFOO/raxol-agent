defmodule Raxol.Payments.Checkpoint.LockTest do
  @moduledoc """
  The lock behind `Raxol.Payments.Checkpoint.ContextStore`: waiters are served
  in order, and the lock passes on when its holder releases or dies, or when a
  waiter dies in the queue.

  Each test learns that a waiter is queued by tracing the lock process for the
  waiter's `:acquire` call, not by waiting on a clock. The lock process is one
  per node and a process has one tracer, so this case is not async.
  """
  use ExUnit.Case, async: false

  alias Raxol.Payments.Checkpoint.Lock

  setup do
    resource = {__MODULE__, System.unique_integer([:positive])}
    # Start the lock process before tracing it.
    :ok = Lock.with_lock(resource, fn -> :ok end)
    server = Process.whereis(Lock)
    :erlang.trace(server, true, [:receive])
    on_exit(fn -> trace_off(server) end)
    %{resource: resource, server: server}
  end

  defp trace_off(server) do
    :erlang.trace(server, false, [:receive])
  rescue
    ArgumentError -> :ok
  end

  # A process that takes the lock, reports `{:holding, self()}` to the test,
  # and keeps it until told `:release`.
  defp holder(resource) do
    test = self()

    spawn(fn ->
      Lock.with_lock(resource, fn ->
        send(test, {:holding, self()})
        receive(do: (:release -> :ok))
      end)
    end)
  end

  defp await_holding(pid), do: receive(do: ({:holding, ^pid} -> :ok))

  # Returns once `pid`'s acquire is in the lock process's mailbox: anything
  # the lock process receives after this, it handles after that acquire.
  defp await_queued(server, pid, resource) do
    receive do
      {:trace, ^server, :receive, {:"$gen_call", {^pid, _tag}, {:acquire, ^resource}}} -> :ok
    end
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^pid, reason} -> reason))
  end

  test "waiters take the lock one at a time, in the order they asked",
       %{resource: resource, server: server} do
    first = holder(resource)
    await_holding(first)

    second = holder(resource)
    await_queued(server, second, resource)
    third = holder(resource)
    await_queued(server, third, resource)

    refute_received {:holding, ^second}
    send(first, :release)
    await_holding(second)
    refute_received {:holding, ^third}

    send(second, :release)
    await_holding(third)
    send(third, :release)
  end

  test "a holder that dies passes the lock to the next waiter",
       %{resource: resource, server: server} do
    doomed = holder(resource)
    await_holding(doomed)
    next = holder(resource)
    await_queued(server, next, resource)

    assert kill(doomed) == :killed
    await_holding(next)
    send(next, :release)
  end

  test "a waiter that dies in the queue is skipped",
       %{resource: resource, server: server} do
    first = holder(resource)
    await_holding(first)
    gone = holder(resource)
    await_queued(server, gone, resource)
    last = holder(resource)
    await_queued(server, last, resource)

    assert kill(gone) == :killed
    send(first, :release)
    await_holding(last)
    send(last, :release)
  end

  test "an exception inside the lock releases it and reaches the caller",
       %{resource: resource} do
    assert_raise RuntimeError, "boom", fn ->
      Lock.with_lock(resource, fn -> raise "boom" end)
    end

    assert Lock.with_lock(resource, fn -> :again end) == :again
  end

  test "a stray message leaves the lock process serving", %{resource: resource, server: server} do
    send(server, :stray)
    assert Lock.with_lock(resource, fn -> :served end) == :served
    assert Process.whereis(Lock) == server
  end

  test "different resources do not wait on each other", %{resource: resource} do
    held = holder(resource)
    await_holding(held)

    assert Lock.with_lock({resource, :other}, fn -> :free end) == :free
    send(held, :release)
  end
end

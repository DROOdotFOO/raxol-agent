defmodule Raxol.Payments.Checkpoint.LockTest do
  @moduledoc """
  The lock behind `Raxol.Payments.Checkpoint.ContextStore`: waiters are served
  in order; the lock passes on when its holder finishes or dies, when the
  holder's caller dies, or when a waiter dies in the queue; and a lock that
  dies mid-hold aborts the write before a new lock serves anyone.

  Each test learns that a waiter is queued by tracing the lock process for the
  waiter's `:acquire` call, not by waiting on a clock. The lock process is one
  per node and a process has one tracer, so this case is not async.
  """
  use ExUnit.Case, async: false

  alias Raxol.Payments.Checkpoint.Lock

  setup do
    resource = {__MODULE__, System.unique_integer([:positive])}
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

  # A caller that takes the lock. Its writer reports
  # `{:holding, caller, writer}` to the test and keeps the lock until told
  # `:release`. Returns the caller.
  defp holder(resource) do
    test = self()

    spawn(fn ->
      caller = self()

      Lock.with_lock(resource, fn ->
        send(test, {:holding, caller, self()})
        receive(do: (:release -> :ok))
      end)
    end)
  end

  # Returns the writer holding the lock for `caller`.
  defp await_holding(caller), do: receive(do: ({:holding, ^caller, writer} -> writer))

  # Returns once the acquire of `caller`'s writer is in the lock process's
  # mailbox: anything the lock process receives after this, it handles after
  # that acquire.
  defp await_queued(server, caller, resource) do
    receive do
      {:trace, ^server, :receive, {:"$gen_call", _from, {:acquire, ^resource, ^caller}}} -> :ok
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
    first_writer = await_holding(first)

    second = holder(resource)
    await_queued(server, second, resource)
    third = holder(resource)
    await_queued(server, third, resource)

    refute_received {:holding, ^second, _}
    send(first_writer, :release)
    second_writer = await_holding(second)
    refute_received {:holding, ^third, _}

    send(second_writer, :release)
    send(await_holding(third), :release)
  end

  test "a holder that dies passes the lock to the next waiter",
       %{resource: resource, server: server} do
    doomed = await_holding(holder(resource))
    next = holder(resource)
    await_queued(server, next, resource)

    assert kill(doomed) == :killed
    send(await_holding(next), :release)
  end

  test "a caller that dies mid-hold aborts its writer and passes the lock on",
       %{resource: resource, server: server} do
    caller = holder(resource)
    writer = await_holding(caller)
    next = holder(resource)
    await_queued(server, next, resource)

    ref = Process.monitor(writer)
    assert kill(caller) == :killed
    assert_down(ref, writer, :killed)
    send(await_holding(next), :release)
  end

  test "a waiter that dies in the queue is skipped",
       %{resource: resource, server: server} do
    first = await_holding(holder(resource))
    gone = holder(resource)
    await_queued(server, gone, resource)
    last = holder(resource)
    await_queued(server, last, resource)

    assert kill(gone) == :killed
    send(first, :release)
    send(await_holding(last), :release)
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
    held = await_holding(holder(resource))

    assert Lock.with_lock({resource, :other}, fn -> :free end) == :free
    send(held, :release)
  end

  @tag capture_log: true
  test "a lock killed mid-hold aborts the write before a new lock serves anyone",
       %{resource: resource} do
    # A lock tree of this test's own, so the kill below counts against a fresh
    # restart intensity, however often the case repeats.
    :ok = Supervisor.terminate_child(Raxol.Payments.Supervisor, Lock.Supervisor)
    on_exit(fn -> Supervisor.restart_child(Raxol.Payments.Supervisor, Lock.Supervisor) end)
    start_supervised!(Lock.Supervisor)
    server = Process.whereis(Lock)
    test = self()
    wrote = :counters.new(1, [])

    caller =
      spawn(fn ->
        outcome =
          try do
            Lock.with_lock(resource, fn ->
              send(test, {:holding, self()})
              receive(do: (:release -> :ok))
              :counters.add(wrote, 1, 1)
            end)
          catch
            :exit, reason -> {:exited, reason}
          end

        send(test, {:outcome, self(), outcome})
      end)

    writer = receive(do: ({:holding, writer} -> writer))
    ref = Process.monitor(writer)

    assert kill(server) == :killed

    # The supervisor kills the writer before it restarts the lock, and the
    # caller fails closed.
    assert_down(ref, writer, :killed)

    receive(
      do: ({:outcome, ^caller, outcome} -> assert(outcome == {:exited, {:lock_lost, resource}}))
    )

    # The writer's DOWN came from inside the supervisor's restart, so this
    # call is handled once that restart is complete.
    _ = Supervisor.which_children(Lock.Supervisor)
    restarted = Process.whereis(Lock)
    assert is_pid(restarted) and restarted != server

    assert Lock.with_lock(resource, fn -> Process.alive?(writer) end) == false
    assert :counters.get(wrote, 1) == 0
  end

  test "a caller fails closed when the lock is not running", %{resource: resource} do
    lock_sup = Lock.Supervisor
    :ok = Supervisor.terminate_child(lock_sup, Lock.writers())
    on_exit(fn -> Supervisor.restart_child(lock_sup, Lock.writers()) end)

    assert catch_exit(Lock.with_lock(resource, fn -> :never end)) == {:lock_lost, resource}
  end

  defp assert_down(ref, pid, expected) do
    receive(do: ({:DOWN, ^ref, :process, ^pid, reason} -> assert(reason == expected)))
  end
end

defmodule Raxol.Agent.Session.RegistrationTest do
  @moduledoc """
  `Session.Registration.await_free/2` waits on a key's live holder by monitor
  and treats a dead holder's leftover entry as free; `lookup/1` agrees.

  The Registry deletes a dead process's entries when its partition handles
  the exit. Suspending the partitions holds that moment open, so these tests
  see a dead holder's entry still in place without racing the cleanup.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Session.Registration

  @registry Raxol.Agent.Registry

  setup do
    start_supervised!({Registry, keys: :unique, name: @registry})
    %{key: {:registration_test, System.unique_integer([:positive])}}
  end

  # A process that registers `key` and then waits for `:stop`. With
  # `on_terminate`, it traps exits and, asked to stop, holds on until it gets
  # `:let_go`, a holder that is shutting down but not yet gone.
  defp holder(key, opts \\ []) do
    test = self()

    pid =
      spawn(fn ->
        if opts[:slow_exit], do: Process.flag(:trap_exit, true)
        {:ok, _} = Registry.register(@registry, key, :held)
        send(test, {:registered, self()})

        receive do
          {:EXIT, _from, _reason} -> receive(do: (:let_go -> :ok))
          :stop -> :ok
        end
      end)

    receive(do: ({:registered, ^pid} -> pid))
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^pid, _reason} -> :ok))
  end

  defp with_partitions_suspended(fun) do
    partitions = for {_id, pid, _type, _mods} <- Supervisor.which_children(@registry), do: pid
    Enum.each(partitions, &:sys.suspend/1)

    try do
      fun.()
    after
      Enum.each(partitions, &:sys.resume/1)
    end
  end

  # Returns once `watcher` monitors `pid`. It yields between looks rather
  # than sleeping: the monitor is the only sign that `await_free/2` is
  # waiting, and nothing else can be waited on for it.
  defp await_monitor(pid, watcher) do
    {:monitored_by, watchers} = Process.info(pid, :monitored_by)

    unless watcher in watchers do
      :erlang.yield()
      await_monitor(pid, watcher)
    end
  end

  describe "await_free/2" do
    test "returns for a key nobody holds", %{key: key} do
      assert Registration.await_free(key, 0) == :ok
    end

    test "treats a dead holder's leftover entry as free", %{key: key} do
      dead = holder(key)

      with_partitions_suspended(fn ->
        kill(dead)
        assert [{^dead, :held}] = Registry.lookup(@registry, key)

        # With no budget at all: a free key needs no waiting.
        assert Registration.await_free(key, 0) == :ok
        assert Registration.lookup(key) == nil

        # And the key really is free: registering it replaces the entry.
        assert {:ok, _owner} = Registry.register(@registry, key, :mine)
        assert Registration.lookup(key) == self()
      end)
    end

    test "returns once a live holder exits", %{key: key} do
      stopping = holder(key, slow_exit: true)
      Process.exit(stopping, :shutdown)
      test = self()

      spawn_link(fn ->
        await_monitor(stopping, test)
        send(stopping, :let_go)
      end)

      assert Registration.await_free(key, 60_000) == :ok
      refute Process.alive?(stopping)
    end

    test "falls through once the budget is spent on a holder that stays", %{key: key} do
      staying = holder(key)

      assert Registration.await_free(key, 0) == :ok
      assert Registration.lookup(key) == staying
      send(staying, :stop)
    end
  end

  describe "lookup/1" do
    test "is nil for a holder that has exited, even before the registry cleans up",
         %{key: key} do
      dead = holder(key)

      with_partitions_suspended(fn ->
        kill(dead)
        assert [{^dead, :held}] = Registry.lookup(@registry, key)
        assert Registration.lookup(key) == nil
      end)
    end
  end
end

defmodule Raxol.Payments.Checkpoint.ContextStoreTest do
  # async: false -- Raxol.Agent.ContextStore is a single global named ETS table.
  use ExUnit.Case, async: false

  alias Raxol.Agent.ContextStore
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Checkpoint.ContextStore, as: Bridge
  alias Raxol.Payments.Checkpoint.Lock

  @ids [:cp_bridge_a, :cp_bridge_b, :cp_bridge_crash]

  setup do
    ContextStore.init()
    on_exit(fn -> Enum.each(@ids, &ContextStore.delete/1) end)
    :ok
  end

  test "round-trips a record" do
    store = Bridge.new(:cp_bridge_a)

    assert :error = Checkpoint.fetch(store, "k")
    assert :ok = Checkpoint.put(store, "k", %{intent_id: "int_1", status: :dispatched})
    assert {:ok, %{intent_id: "int_1", status: :dispatched}} = Checkpoint.fetch(store, "k")
    assert :ok = Checkpoint.delete(store, "k")
    assert :error = Checkpoint.fetch(store, "k")
  end

  test "a first write creates the ContextStore table for the caller, not the lock's writer" do
    # The test process owns the table `setup` created, so it may drop it.
    :ets.delete(:raxol_agent_contexts)
    store = Bridge.new(:cp_bridge_a)

    assert :ok = Checkpoint.put(store, "k", %{intent_id: "int_1"})
    assert :ets.info(:raxol_agent_contexts, :owner) == self()
    assert {:ok, %{intent_id: "int_1"}} = Checkpoint.fetch(store, "k")
  end

  test "put overwrites the prior record" do
    store = Bridge.new(:cp_bridge_a)
    Checkpoint.put(store, "k", %{intent_id: "int_1", status: :dispatched})
    Checkpoint.put(store, "k", %{intent_id: "int_1", status: :in_flight})

    assert {:ok, %{status: :in_flight}} = Checkpoint.fetch(store, "k")
  end

  test "put_new has one owner under concurrent acquisition" do
    store = Bridge.new(:cp_bridge_a)
    parent = self()

    tasks =
      for owner <- 1..16 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Checkpoint.put_new(store, "shared", %{owner: owner})
          end
        end)
      end

    # Every task is waiting for :go before any gets it. Each task is linked, so
    # one that crashes fails the test instead of leaving this receive waiting.
    for %Task{pid: pid} <- tasks, do: receive(do: ({:ready, ^pid} -> :ok))

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :exists})) == 15
    assert {:ok, %{owner: owner}} = Checkpoint.fetch(store, "shared")
    assert owner in 1..16
  end

  test "a dead lock holder cannot leak the ContextStore acquisition lock" do
    store = Bridge.new(:cp_bridge_a)
    parent = self()
    resource = {Bridge, :cp_bridge_a}

    holder =
      spawn(fn ->
        caller = self()

        # `fun` runs in the lock's writer process; killing the caller below
        # aborts that writer too.
        Lock.with_lock(resource, fn ->
          send(parent, {:locked, caller})
          receive(do: (:stop -> :ok))
        end)
      end)

    receive(do: ({:locked, ^holder} -> :ok))
    ref = Process.monitor(holder)
    task = Task.async(fn -> Checkpoint.put_new(store, "after_crash", %{owner: :survivor}) end)

    Process.exit(holder, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^holder, reason} -> assert(reason == :killed)))
    assert :ok = Task.await(task)
    assert {:ok, %{owner: :survivor}} = Checkpoint.fetch(store, "after_crash")
  end

  test "concurrent writes to different keys of one store all land" do
    store = Bridge.new(:cp_bridge_a)
    keys = for n <- 1..32, do: "k#{n}"

    keys
    |> Enum.map(&Task.async(fn -> Checkpoint.put(store, &1, %{key: &1}) end))
    |> Task.await_many()

    for key <- keys, do: assert({:ok, %{key: ^key}} = Checkpoint.fetch(store, key))
  end

  test "sweep removes only expired records" do
    store = Bridge.new(:cp_bridge_a)
    Checkpoint.put(store, "expired", %{expires_at: 10})
    Checkpoint.put(store, "fresh", %{expires_at: 12})

    assert :ok = Checkpoint.sweep_expired(store, 10)
    assert :error = Checkpoint.fetch(store, "expired")
    assert {:ok, %{expires_at: 12}} = Checkpoint.fetch(store, "fresh")
  end

  test "two store ids are isolated" do
    a = Bridge.new(:cp_bridge_a)
    b = Bridge.new(:cp_bridge_b)

    Checkpoint.put(a, "k", %{intent_id: "from_a"})
    Checkpoint.put(b, "k", %{intent_id: "from_b"})

    assert {:ok, %{intent_id: "from_a"}} = Checkpoint.fetch(a, "k")
    assert {:ok, %{intent_id: "from_b"}} = Checkpoint.fetch(b, "k")
  end

  test "a record survives the process that wrote it (the crash it protects against)" do
    store = Bridge.new(:cp_bridge_crash)

    {:ok, writer} = Task.start(fn -> Checkpoint.put(store, "k", %{intent_id: "int_1"}) end)
    ref = Process.monitor(writer)
    receive(do: ({:DOWN, ^ref, :process, ^writer, _reason} -> :ok))

    # The writer is gone; the record persists in the store the test process owns,
    # the way an agent's in-flight intent outlives the crashed agent.
    assert {:ok, %{intent_id: "int_1"}} = Checkpoint.fetch(store, "k")
  end
end

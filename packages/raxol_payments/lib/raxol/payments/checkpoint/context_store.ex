defmodule Raxol.Payments.Checkpoint.ContextStore do
  @moduledoc """
  `Raxol.Payments.Checkpoint` store backed by `Raxol.Agent.ContextStore`.

  This is the recovery store for a deployed agent: the in-flight intent persists
  in the same durable context store that backs the agent's own crash recovery, so
  it survives the same restart. A payment Action that crashes mid-settlement
  resumes the checkpointed intent instead of re-signing.

  ## Why a dedicated namespace

  `Raxol.Agent.Process` saves an agent's snapshot with `ContextStore.save/2`,
  which **replaces** the whole entry. Storing checkpoints under the agent's own id
  would be clobbered on the next snapshot, so this store addresses a dedicated id,
  distinct from any agent id, whose entire context map is the key-to-record store.

  ## Availability

  As a Hex dependency, raxol_agent is an ordinary dependency of raxol_payments:
  a release that depends on raxol_payments includes and starts it, so this
  store is available. Inside this package's repository the dependency is
  `runtime: false`; where raxol_agent's modules are not loaded the store
  degrades to a no-op: `fetch` misses, `put`/`delete` do nothing, and recovery
  is simply disabled -- the same as configuring no checkpoint at all.

  ## Concurrency

  The whole store is one `ContextStore` entry, and every write rewrites it, so
  `put/3`, `put_new/3`, `delete/2` and `sweep_expired/2` each take a per-store
  `Raxol.Payments.Checkpoint.Lock`. That makes `put_new/3` one owner per key,
  and keeps a write from erasing a concurrent one. `fetch/2` reads without it.

  The lock lives in the `raxol_payments` application tree and fails closed: a
  write whose lock is not running, or exits mid-write, is aborted and the
  caller exits with `{:lock_lost, resource}`, rather than returning as though
  the checkpoint were stored.

  ## Durability

  Inherits `ContextStore`'s durability: its ETS table survives a process crash
  only while owned by a process that outlives the crash. An agent app initializes
  the table at supervisor level, so it persists across an individual agent's
  restart; it does not survive a VM restart.
  """

  @behaviour Raxol.Payments.Checkpoint

  @compile {:no_warn_undefined, Raxol.Agent.ContextStore}

  alias Raxol.Payments.Checkpoint.Lock

  @context_store Raxol.Agent.ContextStore

  @doc """
  Build the `{module, handle}` store for a dedicated `store_id`.

  `store_id` must be an atom distinct from any agent id (its `ContextStore` entry
  is replaced wholesale by this store, so it cannot be shared with an agent's
  snapshot).
  """
  @spec new(atom()) :: Raxol.Payments.Checkpoint.store()
  def new(store_id) when is_atom(store_id), do: {__MODULE__, store_id}

  @impl true
  def fetch(store_id, key) do
    with true <- available?(),
         {:ok, records} <- @context_store.load(store_id),
         {:ok, record} <- Map.fetch(records, key) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  @impl true
  def put(store_id, key, record) do
    if available?(), do: with_lock(store_id, fn -> write(store_id, key, record) end)
    :ok
  end

  @impl true
  def put_new(store_id, key, record) do
    if available?(),
      do: with_lock(store_id, fn -> put_unless_present(store_id, key, record) end),
      else: :ok
  end

  @impl true
  def delete(store_id, key) do
    if available?(),
      do: with_lock(store_id, fn -> @context_store.update(store_id, &Map.delete(&1, key)) end)

    :ok
  end

  @impl true
  def sweep_expired(store_id, now) do
    if available?(),
      do: with_lock(store_id, fn -> sweep_records(store_id, now) end),
      else: :ok
  end

  # Every write is a read-modify-write of the whole entry (`ContextStore.update/2`
  # loads, applies and saves), so two unlocked writes to one store lose one of
  # them: a `put` landing inside `put_new`'s fetch-then-write would erase the
  # claim `put_new` just made. All writes to a store therefore take its lock.
  #
  # `fun` runs in the lock's short-lived writer process, and `ContextStore`
  # creates its ETS table in whichever process first touches it, so the
  # caller creates it first: a table the writer created would die with it,
  # and every checkpoint with the table.
  defp with_lock(store_id, fun) do
    :ok = @context_store.init()
    Lock.with_lock({__MODULE__, store_id}, fun)
  end

  # Called with the store's lock held; the lock is not reentrant.
  defp write(store_id, key, record) do
    case @context_store.update(store_id, &Map.put(&1, key, record)) do
      {:ok, _records} -> :ok
      {:error, :not_found} -> @context_store.save(store_id, %{key => record})
    end
  end

  defp put_unless_present(store_id, key, record) do
    case fetch(store_id, key) do
      :error ->
        write(store_id, key, record)
        :ok

      {:ok, _record} ->
        {:error, :exists}
    end
  end

  defp sweep_records(store_id, now) do
    case @context_store.update(store_id, &Map.reject(&1, fn entry -> expired?(entry, now) end)) do
      {:ok, _records} -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp expired?({_key, record}, now),
    do: is_map(record) and is_integer(record[:expires_at]) and record.expires_at <= now

  defp available?, do: Code.ensure_loaded?(@context_store)
end

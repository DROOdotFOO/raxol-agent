defmodule Raxol.Payments.Checkpoint.Lock.Supervisor do
  @moduledoc """
  The lock process of `Raxol.Payments.Checkpoint.Lock` and, after it, the
  supervisor of its writers, `:rest_for_one`.

  The order is the guarantee: when the lock process exits, this supervisor
  shuts the writer supervisor down (killing each writer and waiting for it to
  be gone) before it starts a new lock process, so a fresh lock never runs
  alongside a writer the old one admitted.
  """

  use Supervisor

  alias Raxol.Payments.Checkpoint.Lock

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Supervisor.init([Lock, {Task.Supervisor, name: Lock.writers()}], strategy: :rest_for_one)
  end
end

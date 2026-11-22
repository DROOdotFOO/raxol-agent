defmodule Raxol.Payments.Application do
  @moduledoc false
  # The raxol_payments supervision tree: the lock behind
  # `Raxol.Payments.Checkpoint.ContextStore` writes.

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Raxol.Payments.Checkpoint.Lock.Supervisor],
      strategy: :one_for_one,
      name: Raxol.Payments.Supervisor
    )
  end
end

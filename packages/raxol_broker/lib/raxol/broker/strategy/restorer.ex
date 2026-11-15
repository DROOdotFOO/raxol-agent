defmodule Raxol.Broker.Strategy.Restorer do
  @moduledoc """
  Starts every strategy the journal holds as added when it starts, then
  idles. It is a permanent child placed after the runners' supervisor in
  `Raxol.Broker.Strategy.Supervisor`, so any restart of the runners (or of
  the strategy supervisor) restarts it and restores them.

  The restore runs in `handle_continue/2`, after `init/1` returns, so the
  strategy supervisor's start never waits on the journal.
  """

  use GenServer

  require Logger

  alias Raxol.Broker.Strategy

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts), do: {:ok, opts, {:continue, :restore}}

  @impl GenServer
  def handle_continue(:restore, opts) do
    restore_opts = [supervisor: opts[:supervisor], journal: opts[:journal]]

    with {:error, reason} <- Strategy.Supervisor.restore(restore_opts) do
      Logger.error(
        "[Broker.Strategy] strategies not restored: #{inspect(reason, structs: false)}"
      )
    end

    {:noreply, opts, :hibernate}
  end
end

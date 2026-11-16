defmodule Mix.Tasks.Raxol.Broker.Beat do
  @moduledoc """
  Beats the dead-man switch (`Raxol.Broker.Heartbeat`), resuming strategies
  it paused.

      mix raxol.broker.beat

  Run it in the broker's VM (`iex -S mix`), where the heartbeat runs, as
  `Mix.Task.rerun("raxol.broker.beat")`: `Mix.Task.run/2` runs a task once
  per VM, so a second beat through it would do nothing.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Heartbeat}

  @shortdoc "Beats the broker's dead-man switch"

  @impl Mix.Task
  def run(args) do
    if args != [], do: Mix.raise("usage: mix raxol.broker.beat")

    if Process.whereis(Heartbeat) do
      :ok = Heartbeat.beat("cli")
      CLI.info("beat")
    else
      Mix.raise("no heartbeat runs in this VM; run this from the broker's shell")
    end
  end
end

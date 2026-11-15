defmodule Mix.Tasks.Raxol.Broker.Disarm do
  @moduledoc """
  Disarms the broker: the executor sends no order until it is armed again.
  Cancels still go through.

      mix raxol.broker.disarm [--reason TEXT] [--journal PATH]

  Disarming has no preconditions.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Mode}

  @shortdoc "Disarms the broker"
  @switches [reason: :string, journal: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix raxol.broker.disarm [--reason TEXT]")

    CLI.with_journal(opts[:journal], fn journal ->
      case Mode.disarm(Keyword.get(opts, :reason, "operator"), journal: journal) do
        :ok -> CLI.info("disarmed")
        {:error, reason} -> Mix.raise("disarm not recorded: #{inspect(reason)}")
      end
    end)
  end
end

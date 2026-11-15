defmodule Mix.Tasks.Raxol.Broker.Kill do
  @moduledoc """
  Pulls the kill switch (`Raxol.Broker.Halt.kill/1`): disarms, stops every
  strategy, cancels every open agent-initiated equity order and declines
  every pending trade approval through the executor, and journals it.

      mix raxol.broker.kill [--bound MS] [--journal PATH]

  Run it in the broker's VM (`iex -S mix`): only the running executor can
  cancel. Without one here it disarms and says the orders were not touched.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Executor, Halt, Mode}

  @shortdoc "Disarms, stops strategies, cancels open orders"
  @switches [bound: :integer, journal: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise("usage: mix raxol.broker.kill [--bound MS]")

    CLI.with_journal(opts[:journal], fn journal ->
      if Process.whereis(Executor) do
        {:ok, summary} = Halt.kill(journal: journal, bound: Keyword.get(opts, :bound, 10_000))
        report(summary)
      else
        :ok = Mode.disarm("kill", journal: journal)
        CLI.info("disarmed; no executor runs here, so open orders were not cancelled")
      end
    end)
  end

  defp report(summary) do
    CLI.info("disarmed: #{inspect(summary.disarmed)}")
    CLI.info("orders: #{listed(summary.orders)}  approvals: #{listed(summary.approvals)}")
    Enum.each(summary.results, &CLI.info("#{&1.kind} #{&1.id}: #{&1.outcome}"))
  end

  defp listed({:ok, ids}), do: Integer.to_string(length(ids))

  defp listed({:error, {:incomplete, ids, reasons}}),
    do: "#{length(ids)}, INCOMPLETE (#{inspect(reasons)}); check the app for the rest"

  defp listed({:error, reason}), do: "unreadable (#{inspect(reason)})"
end

defmodule Mix.Tasks.Raxol.Broker.Kill do
  @moduledoc """
  Pulls the kill switch (`Raxol.Broker.Halt.kill/1`): disarms, stops every
  strategy, cancels every open agent-initiated equity order and declines
  every pending trade approval through the executor, and journals it.

      mix raxol.broker.kill [--bound MS] [--journal PATH]

  From another shell, submits an owner-only halt file to the running broker.
  Submission is not proof of cancellation; check the halt journal and app.
  In `iex`, call `Mix.Task.rerun("raxol.broker.kill")`: `Mix.Task.run/2`
  runs a task once per VM, so a second kill through it would do nothing.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Executor, Halt, HaltRequest, Journal, Mode}

  @shortdoc "Disarms, stops strategies, cancels open orders"
  @switches [bound: :integer, journal: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise("usage: mix raxol.broker.kill [--bound MS]")

    bound = Keyword.get(opts, :bound, 10_000)
    if bound <= 0, do: Mix.raise("--bound must be positive")

    if Process.whereis(Journal) do
      kill(Journal, bound)
    else
      {:ok, _apps} = Application.ensure_all_started(:raxol_broker)
      journal_opts = if opts[:journal], do: [path: opts[:journal]], else: []

      # Unlinked: a refused writer lock must not exit this CLI before it
      # can submit the halt marker. This temporary server is stopped below.
      case GenServer.start(Journal, Keyword.put(journal_opts, :name, Journal), name: Journal) do
        {:ok, pid} ->
          try do
            kill(Journal, bound)
          after
            GenServer.stop(pid)
          end

        {:error, {:journal_open_failed, {:journal_locked, _holder}}} ->
          case HaltRequest.request(Journal.path(journal_opts)) do
            :ok ->
              CLI.info("halt requested; new orders blocked; running broker polls within 100 ms")
              CLI.info("cancellation is not confirmed; check the halt journal and Robinhood app")

            {:error, reason} ->
              Mix.raise("cannot submit halt request: #{inspect(reason)}")
          end

        {:error, reason} ->
          Mix.raise("cannot open the broker journal: #{inspect(reason)}")
      end
    end
  end

  defp kill(journal, bound) do
    if Process.whereis(Executor) do
      {:ok, summary} = Halt.kill(journal: journal, bound: bound)
      report(summary)
    else
      :ok = Mode.disarm("kill", journal: journal)
      CLI.info("disarmed; no executor runs here, so open orders were not cancelled")
    end
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

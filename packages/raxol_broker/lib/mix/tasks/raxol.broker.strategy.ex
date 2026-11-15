defmodule Mix.Tasks.Raxol.Broker.Strategy do
  @moduledoc """
  Adds, lists and stops strategies.

      mix raxol.broker.strategy add dip_buy --symbol F --usd 25 [--dip 0.02] [--id ID]
      mix raxol.broker.strategy list
      mix raxol.broker.strategy stop ID

  Each takes `--journal PATH` (default `~/.raxol/broker/journal`,
  `$RAXOL_BROKER_JOURNAL`). Adding and stopping are journaled; with the
  broker running in this VM the runner is also started or stopped, and
  otherwise the broker starts every added strategy when it next starts. A
  strategy places nothing until `mix raxol.broker.arm` has run.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Strategy}

  @shortdoc "Adds, lists and stops broker strategies"
  @switches [symbol: :string, usd: :string, dip: :string, id: :string, journal: :string]
  @params [:symbol, :usd, :dip]
  @usage """
  usage: mix raxol.broker.strategy add NAME [--symbol S --usd N --dip F] [--id ID]
         mix raxol.broker.strategy list
         mix raxol.broker.strategy stop ID
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise(@usage)
    CLI.with_journal(opts[:journal], &command(rest, opts, &1))
  end

  defp command(["add", name], opts, journal) do
    params = for key <- @params, value = opts[key], into: %{}, do: {Atom.to_string(key), value}

    with {:ok, spec} <- Strategy.spec(name, params, opts[:id]),
         :ok <- Strategy.Supervisor.add(spec, journal: journal) do
      CLI.info("added #{spec["id"]} (#{name} #{render(params)})")
    else
      {:error, {:unknown_strategy, _}} ->
        Mix.raise("unknown strategy #{name}; known: #{Enum.join(Strategy.names(), ", ")}")

      {:error, reason} ->
        Mix.raise("strategy not added: #{inspect(reason)}")
    end
  end

  defp command(["list"], _opts, journal) do
    case Strategy.Supervisor.list(journal: journal) do
      {:ok, []} ->
        CLI.info("no strategies")

      {:ok, strategies} ->
        Enum.each(strategies, fn s ->
          CLI.info("#{s.id}  #{s.strategy}  #{render(s.params)}  #{s.status}")
        end)

      {:error, reason} ->
        Mix.raise("cannot list strategies: #{inspect(reason)}")
    end
  end

  defp command(["stop", id], _opts, journal) do
    case Strategy.Supervisor.stop(id, journal: journal) do
      :ok -> CLI.info("stopped #{id}")
      {:error, reason} -> Mix.raise("strategy not stopped: #{inspect(reason)}")
    end
  end

  defp command(_rest, _opts, _journal), do: Mix.raise(@usage)

  defp render(params),
    do: params |> Enum.sort() |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
end

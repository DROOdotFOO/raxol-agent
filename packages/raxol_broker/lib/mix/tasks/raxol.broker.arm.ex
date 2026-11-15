defmodule Mix.Tasks.Raxol.Broker.Arm do
  @moduledoc """
  Arms the broker: from now on the executor may send real orders.

      mix raxol.broker.arm [--policy broker.policy.exs] [--journal PATH]

  Arming runs every check in `Raxol.Broker.Mode.arm/1` (the policy file
  loads, the journal's hash chain verifies, the Robinhood session is
  connected, every strategy's symbols quote at or below
  `max_notional_per_order`), prints what it found, and asks you to type
  `ARM`. Anything else writes nothing. `mix raxol.broker.disarm` undoes it.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Mode, PolicyFile}

  @shortdoc "Arms the broker after its checks and a typed confirmation"
  @switches [policy: :string, journal: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise("usage: mix raxol.broker.arm [--policy PATH]")
    path = Keyword.get(opts, :policy, PolicyFile.filename())

    CLI.with_journal(opts[:journal], fn journal ->
      CLI.with_client(fn client ->
        [journal: journal, client: client, policy_path: path, confirm: &confirm/1]
        |> Mode.arm()
        |> report()
      end)
    end)
  end

  defp confirm(lines) do
    {question, summary} = List.pop_at(lines, -1)
    Enum.each(summary, &CLI.info/1)
    CLI.prompt(question)
  end

  defp report({:ok, _fields}), do: CLI.info("armed")
  defp report({:error, :not_confirmed}), do: Mix.raise("not armed: confirmation not typed")
  defp report({:error, reason}), do: Mix.raise("not armed: #{inspect(reason)}")
end

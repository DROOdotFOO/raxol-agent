defmodule Mix.Tasks.Raxol.Broker.Inspect do
  @moduledoc """
  Prints accounts, buying power, positions, the mode, the journal's status
  and the policy's verdict for a sample intent. Places nothing and calls no
  review tool: every call goes through the read-only session.

      mix raxol.broker.inspect [--sample "buy F 100usd"] [--policy PATH] [--journal PATH]

  Samples: `"buy SYM 100usd"`, `"buy SYM 2"`, `"sell SYM 2"`,
  `"buy SYM 2 @ 10.50"`. See `Raxol.Broker.Snapshot`.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, PolicyFile, Snapshot}

  @shortdoc "Prints accounts, positions, mode and a sample verdict"
  @switches [sample: :string, policy: :string, journal: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix raxol.broker.inspect [--sample TEXT]")

    policy = CLI.policy!(Keyword.get(opts, :policy, PolicyFile.filename()))

    CLI.with_journal(opts[:journal], fn journal ->
      CLI.with_client(fn client ->
        [client: client, journal: journal, policy: policy, sample: opts[:sample]]
        |> Snapshot.lines()
        |> Enum.each(&CLI.info/1)
      end)
    end)
  end
end

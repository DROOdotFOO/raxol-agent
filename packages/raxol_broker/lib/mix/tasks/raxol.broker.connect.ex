defmodule Mix.Tasks.Raxol.Broker.Connect do
  @moduledoc """
  Signs in to Robinhood and checks the session.

      mix raxol.broker.connect [--policy broker.policy.exs]

  Refuses to run unless the policy file loads, so limits exist before any
  credential is stored. Then it runs the browser sign-in
  (`Raxol.Broker.Login`), stores the credential encrypted, connects, and
  reports how the served tools differ from the frozen capture.
  """

  use Mix.Task

  alias Raxol.Broker.{CLI, Connect, Login, PolicyFile}

  @shortdoc "Signs in to Robinhood and reports tool drift"
  @switches [policy: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix raxol.broker.connect [--policy PATH]")

    _policy = CLI.policy!(Keyword.get(opts, :policy, PolicyFile.filename()))
    {:ok, _apps} = Application.ensure_all_started(:raxol_broker)

    case Login.run() do
      :ok -> CLI.info("signed in; credential stored")
      {:error, reason} -> Mix.raise("sign-in failed: #{inspect(reason)}")
    end

    CLI.with_client(fn client ->
      case Connect.report(client) do
        {:ok, lines} ->
          Enum.each(lines, &CLI.info/1)

        {:error, reason} ->
          Mix.raise("connected but the session is not usable: #{inspect(reason)}")
      end
    end)
  end
end

defmodule Mix.Tasks.Raxol.Broker.Evidence do
  @moduledoc """
  Exports allowlisted, pseudonymized recorded evidence as JSON on stdout.

      mix raxol.broker.evidence --date YYYY-MM-DD [--journal PATH]

  Reads the journal without opening a writer, starting a client, reading
  credentials or creating an output file. Hash verification is not live
  transport or cursor-traversal certification; absent evidence is UNVERIFIED.
  """

  use Mix.Task

  alias Raxol.Broker.Journal
  alias Raxol.Broker.Journal.Evidence

  @shortdoc "Exports redacted broker journal evidence as JSON"
  @switches [date: :string, journal: :string]
  @usage "usage: mix raxol.broker.evidence --date YYYY-MM-DD [--journal PATH]"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise(@usage)

    date = parse_date(Keyword.get(opts, :date))
    path = Journal.path(path: Keyword.get(opts, :journal)) || Mix.raise("no journal path")

    case Evidence.run(path, date) do
      {:ok, report} -> IO.puts(Jason.encode!(report))
      {:error, {:broken, offset}} -> Mix.raise("journal hash chain broken at offset #{offset}")
      {:error, :no_journal} -> Mix.raise("no broker journal")
      {:error, _reason} -> Mix.raise("cannot export evidence: journal unreadable or damaged")
    end
  end

  defp parse_date(nil), do: Mix.raise(@usage)

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> Mix.raise("--date must be YYYY-MM-DD")
    end
  end
end

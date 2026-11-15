defmodule Raxol.Broker.CLI do
  @moduledoc """
  What the `mix raxol.broker.*` tasks share.

  A task acts on the broker running in its own VM (started from `iex -S
  mix`, for instance) when there is one: `Raxol.Broker.Journal` is
  registered there. Otherwise it opens the journal itself for the length of
  the task. The journal takes a cross-process writer lock, so a task run from
  another shell while the broker runs is refused with the holder's OS pid.
  """

  alias Raxol.Broker.{Journal, PolicyFile}
  alias Raxol.Broker.MCP.Client

  @doc "Print a line through the Mix shell."
  @spec info(String.t()) :: :ok
  def info(line), do: Mix.shell().info(line)

  @doc "Prompt through the Mix shell; the answer is trimmed, or nil when input ended."
  @spec prompt(String.t()) :: String.t() | nil
  def prompt(question) do
    case Mix.shell().prompt(question) do
      answer when is_binary(answer) -> String.trim(answer)
      _eof -> nil
    end
  end

  @doc """
  Run `fun` with the journal server: the running one, or one opened at
  `path` (nil: `Raxol.Broker.Journal.path/1`'s default) and closed after.
  """
  @spec with_journal(Path.t() | nil, (Journal.server() -> result)) :: result when result: term()
  def with_journal(path, fun) do
    if Process.whereis(Journal) do
      fun.(Journal)
    else
      {:ok, _apps} = Application.ensure_all_started(:raxol_broker)
      opts = if path, do: [path: path], else: []

      case Journal.start_link(opts) do
        {:ok, pid} ->
          try do
            fun.(Journal)
          after
            GenServer.stop(pid)
          end

        {:error, {:journal_open_failed, {:journal_locked, holder}}} ->
          Mix.raise(
            "the broker journal is open in another process (#{inspect(holder)}); " <>
              "run this from that broker's shell"
          )

        {:error, reason} ->
          Mix.raise("cannot open the broker journal: #{inspect(reason)}")
      end
    end
  end

  @doc """
  Run `fun` with the read-only client: the running `Raxol.Broker.MCP.Client`,
  or one started from the stored credential and stopped after.
  """
  @spec with_client((GenServer.server() -> result)) :: result when result: term()
  def with_client(fun) do
    if Process.whereis(Client) do
      fun.(Client)
    else
      {:ok, _apps} = Application.ensure_all_started(:raxol_broker)

      case Client.start_link([]) do
        {:ok, pid} ->
          try do
            fun.(pid)
          after
            GenServer.stop(pid)
          end

        {:error, reason} ->
          Mix.raise(
            "cannot start the Robinhood session: #{inspect(reason)}; sign in with " <>
              "mix raxol.broker.connect"
          )
      end
    end
  end

  @doc "Load the policy file at `path`, or raise naming it."
  @spec policy!(Path.t()) :: keyword()
  def policy!(path) do
    case PolicyFile.load(path) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        Mix.raise(
          "#{path} does not load (#{inspect(reason)}); write one with mix raxol.broker.init"
        )
    end
  end
end

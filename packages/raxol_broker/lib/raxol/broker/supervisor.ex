defmodule Raxol.Broker.Supervisor do
  @moduledoc """
  Root supervisor for a broker install. Add it to your own supervision tree:

      children = [{Raxol.Broker.Supervisor, journal: [path: "/var/lib/broker/journal"]}]

  The package has no application callback, so nothing starts, and nothing
  touches the journal directory, until you start this supervisor.

  ## Strategy

  `:rest_for_one`. Children are ordered so that everything that records
  decisions starts after `Raxol.Broker.Journal` and restarts with it. The
  journal is first: a process that could place an order must never outlive it.

      Journal, Executor, MCP.Client, Feed.Bucket, Feed, Strategy.Supervisor

  ## Options

    * `:name` - supervisor name, default `#{inspect(__MODULE__)}`
    * `:journal` - options for `Raxol.Broker.Journal.start_link/1`
    * `:executor` - options for `Raxol.Broker.Executor.start_link/1`. When
      given, the executor starts after the journal and restarts with it. Its
      `:journal` is always this supervisor's journal: passing a different one
      makes `start_link/1` return `{:error, {:journal_mismatch, given}}`. Its `:name`
      defaults to `Raxol.Broker.Executor`. Omit it to run the journal alone.
    * `:client` - options for the read-only `Raxol.Broker.MCP.Client`
      (`:name` defaults to that module). Omit it to start none.
    * `:feed` - options for `Raxol.Broker.Feed` (`:name` defaults to that
      module, `:client` to the client's name), plus `:bucket`, options for
      the shared `Raxol.Broker.Feed.Bucket`. Omit it to start no feed.
    * `:strategies` - options for `Raxol.Broker.Strategy.Supervisor`
      (`:journal`, `:executor` and `:feed` default to this supervisor's).
      When given, every strategy the journal holds as added is started once
      the supervisor is up.

  ## Restart semantics

  The executor's `init` touches only the journal: it validates its options,
  prepares (but does not connect) its MCP session, claims the journal and
  closes the groups an earlier executor left open. A journal crash therefore
  restarts the executor without waiting on the network, and an unreachable
  endpoint cannot exhaust the restart intensity.

  The MCP session connects after `init`, without blocking the executor. Until
  it is ready, `Raxol.Broker.Executor.run/3` and `approve/3` return
  `{:error, :port_not_ready}` and open nothing. When the connection fails or
  the session dies, the executor logs it and reconnects with exponential
  backoff (1 s doubling to 60 s), so it never needs a manual restart.

  The executor's child spec sets `shutdown` to its place timeout plus its
  review timeout plus 5 s, so stopping the supervisor mid-order waits for the
  order response instead of killing the executor.
  """

  use Supervisor

  alias Raxol.Broker.{Executor, Feed, Journal}
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Strategy

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    # Checked here too: an OTP supervisor wraps any `init/1` error in `:bad_return`.
    with {:ok, _executor} <- executor_children(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end
  end

  @impl Supervisor
  def init(opts) do
    journal_opts = Keyword.get(opts, :journal, [])

    case executor_children(opts) do
      {:ok, executor} ->
        children =
          [{Journal, journal_opts} | executor] ++
            client_children(opts) ++ feed_children(opts) ++ strategy_children(opts)

        Supervisor.init(children, strategy: :rest_for_one)

      {:error, _reason} = error ->
        error
    end
  end

  defp journal_name(opts), do: opts |> Keyword.get(:journal, []) |> Keyword.get(:name, Journal)

  defp executor_children(opts),
    do: executor_children(Keyword.fetch(opts, :executor), journal_name(opts))

  defp executor_children(:error, _journal), do: {:ok, []}

  defp executor_children({:ok, executor_opts}, journal) do
    case Keyword.fetch(executor_opts, :journal) do
      {:ok, given} when given != journal ->
        {:error, {:journal_mismatch, given}}

      _same_or_unset ->
        executor_opts =
          executor_opts
          |> Keyword.put(:journal, journal)
          |> Keyword.put_new(:name, Executor)

        # The tuple goes through Executor.child_spec/1, which sets `shutdown`.
        {:ok, [{Executor, executor_opts}]}
    end
  end

  defp client_children(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, client_opts} -> [{Client, Keyword.put_new(client_opts, :name, Client)}]
      :error -> []
    end
  end

  defp feed_children(opts) do
    case Keyword.fetch(opts, :feed) do
      {:ok, feed_opts} ->
        {bucket_opts, feed_opts} = Keyword.pop(feed_opts, :bucket, [])
        bucket = Keyword.get(bucket_opts, :name, Feed.Bucket)
        client = opts |> Keyword.get(:client, []) |> Keyword.get(:name, Client)

        feed_opts =
          feed_opts
          |> Keyword.put_new(:name, Feed)
          |> Keyword.put_new(:client, client)
          |> Keyword.put(:bucket, bucket)

        [{Feed.Bucket, Keyword.put(bucket_opts, :name, bucket)}, {Feed, feed_opts}]

      :error ->
        []
    end
  end

  defp strategy_children(opts) do
    case Keyword.fetch(opts, :strategies) do
      {:ok, strategy_opts} ->
        executor = opts |> Keyword.get(:executor, []) |> Keyword.get(:name, Executor)
        feed = if Keyword.has_key?(opts, :feed), do: feed_name(opts)

        strategy_opts =
          strategy_opts
          |> Keyword.put(:journal, journal_name(opts))
          |> Keyword.put_new(:executor, executor)
          |> Keyword.put_new(:feed, feed)
          |> Keyword.put_new(:name, Strategy.Supervisor)

        restore = [supervisor: strategy_opts[:name], journal: journal_name(opts)]

        [
          {Strategy.Supervisor, strategy_opts},
          Supervisor.child_spec({Task, fn -> Strategy.Supervisor.restore(restore) end},
            id: :restore_strategies
          )
        ]

      :error ->
        []
    end
  end

  defp feed_name(opts), do: opts |> Keyword.get(:feed, []) |> Keyword.get(:name, Feed)
end

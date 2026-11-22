defmodule Raxol.Broker.Test.JournalCase do
  @moduledoc """
  `Raxol.Broker.Journal` against a real hash-chained store on disk, with an
  `Agent` clock (`ctx.clock`, moved with `at/2`). Each test gets fresh
  `ctx.opts`, `ctx.name` and `ctx.path`; the helpers below are imported.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Intent, Journal, Policy, PolicyFile}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.ExecutorIdentity

  @t0 ~U[2026-10-02 14:30:00.000000Z]
  @day ~U[2026-10-02 00:00:00.000000Z]

  using do
    quote do
      import Raxol.Broker.Test.JournalCase, except: [t0: 0, day: 0]

      @moduletag :capture_log
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "broker-journal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, clock} = Agent.start_link(fn -> @t0 end)
    name = :"broker_journal_#{System.unique_integer([:positive])}"
    opts = [name: name, path: Path.join(base, "journal"), clock: fn -> Agent.get(clock, & &1) end]
    {:ok, opts: opts, name: name, clock: clock, path: Path.join(base, "journal")}
  end

  @spec t0() :: DateTime.t()
  def t0, do: @t0

  @spec day() :: DateTime.t()
  def day, do: @day

  @spec d(String.t()) :: Decimal.t()
  def d(value), do: Decimal.new(value)

  # Start a journal and claim it for the test process, the only writer of
  # `placing`. The journal only lets an Executor claim, so the test process
  # impersonates one.
  @spec start!(keyword()) :: pid()
  def start!(opts) do
    pid = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
    ExecutorIdentity.assume!(opts[:name])
    pid
  end

  @spec at(pid(), DateTime.t()) :: :ok
  def at(clock, datetime), do: Agent.update(clock, fn _ -> datetime end)

  @spec context(keyword()) :: Context.t()
  def context(overrides \\ []) do
    {:ok, policy} = PolicyFile.new(d("1000"), d("5000"))

    struct!(
      %Context{
        policy: policy,
        portfolio_value: d("100000"),
        start_of_day_value: d("100000"),
        day_pnl: d("0"),
        quotes: %{"AAPL" => d("125")},
        today_notional: d("0"),
        orders_last_minute: 0,
        market_session: :regular
      },
      overrides
    )
  end

  @spec limit(String.t(), String.t()) :: Intent.t()
  def limit(qty, price \\ "125") do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d(qty), d(price), provenance: :strategy)
    intent
  end

  # The full happy path: both policy passes allow, the order is marked as
  # placing and then placed.
  @spec placed_entries(Intent.t(), Context.t(), map() | nil) :: [Journal.entry()]
  def placed_entries(intent, context, response \\ nil) do
    {:allow, _} = verdict = Policy.evaluate(intent, context)

    [
      {:verdict, :pre_review, verdict},
      {:review, %{"warnings" => []}},
      {:verdict, :post_review, verdict},
      {:placing},
      {:order, :placed, response || %{"order_id" => "o-#{intent.id}"}}
    ]
  end

  # Open a group and write it up to (not including) the order call: both
  # passes allow, then `placing`.
  @spec in_flight!(atom(), Intent.t(), Context.t()) :: String.t()
  def in_flight!(name, intent, context) do
    {:ok, id} = Journal.open_group(intent, context, name)

    placed_entries(intent, context)
    |> Enum.drop(-1)
    |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))

    id
  end

  @spec counters(atom(), DateTime.t()) :: {term(), term()}
  def counters(name, now) do
    {Journal.today_notional(@day, name), Journal.orders_last_minute(now, name)}
  end

  @spec records(Path.t()) :: [map()]
  def records(path) do
    {base, session} = Journal.location(path)
    {:ok, records} = FileStore.read_records(session, base_dir: base)
    records
  end

  @spec writer!(Path.t()) :: pid() | nil
  def writer!(path) do
    {base, session} = Journal.location(path)
    Writer.whereis(Path.join(base, session))
  end

  @spec kill_writer!(Path.t(), pid()) :: term()
  def kill_writer!(path, journal) do
    writer = writer!(path)
    ref = Process.monitor(journal)
    # Erlang orders signals per sender/receiver pair only, so the writer's exit
    # (writer -> journal) can overtake the monitor request (test -> journal) and
    # turn the :DOWN into :noproc. A call returns only after the journal has
    # processed the monitor request ahead of it.
    _ = :sys.get_state(journal)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^journal, {:journal_writer_down, :killed}}, 5_000
  end
end

defmodule Raxol.Broker.Test.ExecutorCase do
  @moduledoc """
  The executor end to end against an in-process MCP server speaking real
  JSON-RPC through the HTTP transport's `:exchange` seam
  (`Raxol.Broker.MCP.Fake`), with a real hash-chained journal on disk.

  Each test gets a fresh journal (`ctx.journal`, `ctx.path`,
  `ctx.journal_opts`) and a fake server (`ctx.server`); the helpers below
  are imported.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Executor, Intent, Journal, PolicyFile}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context

  @t0 ~U[2026-10-02 14:30:00.000000Z]
  @day ~U[2026-10-02 00:00:00.000000Z]
  @account "ACC-1"

  defmodule EvilRegistry do
    @moduledoc false
    # Resolving a `{:via, EvilRegistry, pid}` would run this in the caller.
    def whereis_name(pid) do
      send(pid, {:evil_registry, self()})
      :undefined
    end
  end

  using do
    quote do
      import Raxol.Broker.Test.ExecutorCase, except: [t0: 0, day: 0, account: 0]

      @moduletag :capture_log
    end
  end

  setup_all do
    unless Code.ensure_loaded?(Raxol.MCP.Client.ReferenceServer.Legacy) and
             Code.ensure_loaded?(Raxol.MCP.Client.Transport.Http) do
      raise "raxol_broker tests need raxol_mcp built with plug and mint"
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "broker-exec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    path = Path.join(base, "journal")
    name = :"broker_exec_journal_#{System.unique_integer([:positive])}"
    journal_opts = [name: name, path: path, clock: fn -> @t0 end]
    start_journal!(journal_opts)

    {:ok, journal: name, journal_opts: journal_opts, path: path, server: Fake.start()}
  end

  @doc "The fixed clock every journal and executor here runs on."
  @spec t0() :: DateTime.t()
  def t0, do: @t0

  @spec day() :: DateTime.t()
  def day, do: @day

  @spec account() :: String.t()
  def account, do: @account

  @spec d(String.t()) :: Decimal.t()
  def d(value), do: Decimal.new(value)

  @spec policy(String.t(), String.t()) :: keyword()
  def policy(per_order \\ "1000", cap \\ "5000") do
    {:ok, policy} = PolicyFile.new(d(per_order), d(cap))
    policy
  end

  @spec start_journal!(keyword()) :: pid()
  def start_journal!(opts) do
    id = {Journal, System.unique_integer([:positive])}
    start_supervised!(Supervisor.child_spec({Journal, opts}, id: id, restart: :temporary))
  end

  @spec restart_journal!(map(), keyword()) :: pid()
  def restart_journal!(ctx, extra \\ []) do
    if pid = GenServer.whereis(ctx.journal), do: stop_and_wait(pid)
    start_journal!(Keyword.merge(ctx.journal_opts, extra))
  end

  @spec executor_opts(map(), keyword()) :: keyword()
  def executor_opts(ctx, extra) do
    Keyword.merge(
      [
        journal: ctx.journal,
        session: Fake.session(ctx.server),
        account_number: @account,
        policy: policy(),
        clock: fn -> @t0 end
      ],
      extra
    )
  end

  @spec start_executor!(map(), keyword()) :: pid()
  def start_executor!(ctx, extra \\ []) do
    id = {Executor, System.unique_integer([:positive])}

    executor =
      start_supervised!(
        Supervisor.child_spec({Executor, executor_opts(ctx, extra)}, id: id, restart: :temporary)
      )

    :ok = Executor.await_port(executor, 5_000)
    executor
  end

  @doc "A loose caller context: the executor's `:policy` wins over this one."
  @spec context() :: Context.t()
  def context do
    %Context{
      policy: policy("1000000", "1000000"),
      portfolio_value: d("100000"),
      start_of_day_value: d("100000"),
      day_pnl: d("0"),
      quotes: %{"AAPL" => d("125")},
      market_session: :regular
    }
  end

  @spec limit(String.t(), keyword()) :: Intent.t()
  def limit(id, opts \\ []) do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", d("2"), d("125"), [provenance: :strategy, id: id] ++ opts)

    intent
  end

  @spec records(Path.t()) :: [map()]
  def records(path) do
    {base, session} = Journal.location(path)
    {:ok, records} = FileStore.read_records(session, base_dir: base)
    records
  end

  @spec group(Path.t(), String.t()) :: [map()]
  def group(path, group_id), do: Enum.filter(records(path), &(&1["group_id"] == group_id))

  @spec types(Path.t(), String.t()) :: [String.t()]
  def types(path, group_id), do: Enum.map(group(path, group_id), & &1["type"])

  @spec groups_for(Path.t(), String.t()) :: [String.t()]
  def groups_for(path, intent_id) do
    path
    |> records()
    |> Enum.filter(&(&1["type"] == "intent" and &1["intent"]["id"] == intent_id))
    |> Enum.map(& &1["group_id"])
  end

  @spec writer(Path.t()) :: pid() | nil
  def writer(path) do
    {base, session} = Journal.location(path)
    Writer.whereis(Path.join(base, session))
  end

  @spec stop_and_wait(pid(), term()) :: true
  def stop_and_wait(pid, reason \\ :kill) do
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  @spec flip_byte!(Path.t()) :: :ok
  def flip_byte!(path) do
    [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))
    bytes = File.read!(segment)
    at = div(byte_size(bytes), 2)
    <<pre::binary-size(^at), byte, post::binary>> = bytes
    File.write!(segment, <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>)
  end

  # The executor answers `:sys` requests while a review is in flight, so
  # these spin on real state, not on time.
  @spec wait_queued(pid(), pos_integer()) :: nil
  def wait_queued(executor, n) do
    if :queue.len(:sys.get_state(executor).queue) < n, do: wait_queued(executor, n)
  end

  @spec wait_drained(pid()) :: nil
  def wait_drained(executor) do
    if :queue.len(:sys.get_state(executor).queue) > 0, do: wait_drained(executor)
  end

  @spec place_requests(pid()) :: [tuple()]
  def place_requests(fake),
    do: for({"tools/call", "place_" <> _, _status} = request <- Fake.requests(fake), do: request)
end

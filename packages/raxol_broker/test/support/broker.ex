defmodule Raxol.Broker.Test.Broker do
  @moduledoc """
  Real processes for broker tests: a journal in a fresh temporary directory
  and an executor on a `Raxol.Broker.MCP.Fake` session, both started under
  the test's supervisor.
  """

  import ExUnit.Callbacks

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.{Executor, Journal, PolicyFile}

  @t0 ~U[2026-10-02 14:30:00.000000Z]

  @doc "A fixed instant tests use as now."
  def t0, do: @t0

  def d(value), do: Decimal.new(value)

  def policy(per_order \\ "1000", cap \\ "5000", extra \\ []) do
    {:ok, policy} = PolicyFile.new(d(per_order), d(cap))
    Keyword.merge(policy, extra)
  end

  @doc """
  Start a journal in a temporary directory: `%{journal, path, journal_opts,
  base}`. `opts` are merged into the journal options (e.g. `:clock`).
  """
  def journal!(opts \\ []) do
    base = Path.join(System.tmp_dir!(), "broker-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    name = :"broker_test_journal_#{System.unique_integer([:positive])}"
    path = Path.join(base, "journal")
    journal_opts = Keyword.merge([name: name, path: path, clock: fn -> @t0 end], opts)
    start_journal!(journal_opts)
    %{journal: name, path: path, journal_opts: journal_opts, base: base}
  end

  def start_journal!(opts) do
    id = {Journal, System.unique_integer([:positive])}
    start_supervised!(Supervisor.child_spec({Journal, opts}, id: id, restart: :temporary))
  end

  @doc "Start an executor on `fake` writing to `journal`, and wait for its port."
  def executor!(journal, fake, extra \\ []) do
    opts =
      Keyword.merge(
        [
          journal: journal,
          session: Raxol.Broker.MCP.Fake.session(fake),
          account_number: "ACC-1",
          policy: policy(),
          clock: fn -> @t0 end
        ],
        extra
      )

    id = {Executor, System.unique_integer([:positive])}
    pid = start_supervised!(Supervisor.child_spec({Executor, opts}, id: id, restart: :temporary))
    :ok = Executor.await_port(pid, 5_000)
    pid
  end

  @doc "Every record in the journal at `path`, in order."
  def records(path) do
    {base, session} = Journal.location(path)
    {:ok, records} = FileStore.read_records(session, base_dir: base)
    records
  end

  @doc "Flip one bit in the middle of the journal's segment file."
  def flip_byte!(path) do
    [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))
    bytes = File.read!(segment)
    at = div(byte_size(bytes), 2)
    <<pre::binary-size(^at), byte, post::binary>> = bytes
    File.write!(segment, <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>)
  end

  @doc "A clock an `Agent` holds; `{clock_fun, agent}`."
  def clock(start) do
    {:ok, agent} = Agent.start_link(fn -> start end)
    {fn -> Agent.get(agent, & &1) end, agent}
  end
end

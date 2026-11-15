# Kill-to-all-cancelled latency against the Fake.
#
#     MIX_ENV=test mix run bench/kill_latency.exs [ORDERS] [RUNS]
#
# Each run starts a fresh journal and executor on the Fake, places ORDERS
# limit orders (default 5), then times `Raxol.Broker.Halt.kill/1` until it
# returns with every order cancelled. Prints the min, median and max over
# RUNS runs (default 20). The Fake answers in process, so this is the
# broker's own overhead: journal writes, the listing and the parallel
# cancels, without network latency.

alias Raxol.Broker.{Executor, Halt, Intent, Journal, PolicyFile}
alias Raxol.Broker.MCP.Fake
alias Raxol.Broker.Policy.Context

{orders, runs} =
  case System.argv() do
    [o, r] -> {String.to_integer(o), String.to_integer(r)}
    [o] -> {String.to_integer(o), 20}
    [] -> {5, 20}
  end

{:ok, policy} = PolicyFile.new(Decimal.new("100000"), Decimal.new("1000000"))

run = fn i ->
  base = Path.join(System.tmp_dir!(), "broker-bench-#{System.unique_integer([:positive])}")
  journal = :"bench_journal_#{i}"
  {:ok, journal_pid} = Journal.start_link(name: journal, path: Path.join(base, "journal"))
  :ok = Journal.put_mode(:armed, %{"by" => "bench"}, journal)
  fake = Fake.start(quotes: %{"F" => "10"})

  {:ok, executor} =
    Executor.start_link(
      journal: journal,
      session: Fake.session(fake),
      account_number: "BENCH",
      policy: policy
    )

  :ok = Executor.await_port(executor, 5_000)

  for n <- 1..orders do
    {:ok, intent} =
      Intent.limit(:buy, "F", Decimal.new(1), Decimal.new(10), provenance: :human, id: "b#{n}")

    {:ok, %{status: :placed}} = Executor.run(executor, intent, %Context{})
  end

  {micros, {:ok, summary}} =
    :timer.tc(fn ->
      Halt.kill(journal: journal, executor: executor, strategies: :no_strategies, trigger: "bench")
    end)

  true = Enum.all?(summary.results, &(&1.outcome == "placed"))
  true = Enum.all?(Fake.orders(fake), &(&1["state"] == "cancelled"))

  GenServer.stop(executor)
  GenServer.stop(journal_pid)
  File.rm_rf!(base)
  micros
end

times = 1..runs |> Enum.map(run) |> Enum.sort()
ms = fn us -> :erlang.float_to_binary(us / 1000, decimals: 1) end

IO.puts(
  "kill, #{orders} open orders, #{runs} runs: " <>
    "min #{ms.(hd(times))} ms, median #{ms.(Enum.at(times, div(runs, 2)))} ms, " <>
    "max #{ms.(List.last(times))} ms"
)

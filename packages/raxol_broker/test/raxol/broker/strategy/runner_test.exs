defmodule Raxol.Broker.Strategy.RunnerTest do
  @moduledoc """
  Runners against a real journal and an executor on the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Intent, Journal, Strategy}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    ctx = Broker.journal!()
    fake = Fake.start(quotes: %{"F" => "9.80"})
    executor = Broker.executor!(ctx.journal, fake)
    sup_name = :"strategies_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Strategy.Supervisor,
       name: sup_name, journal: ctx.journal, executor: executor, clock: &Broker.t0/0}
    )

    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
    opts = [journal: ctx.journal, supervisor: sup_name]
    :ok = Strategy.Supervisor.add(spec, opts)
    [{runner, _info}] = Strategy.Supervisor.running(sup_name)

    Map.merge(ctx, %{fake: fake, executor: executor, sup: sup_name, opts: opts, runner: runner})
  end

  defp quote!(runner, price),
    do: send(runner, {:quote, "F", %{last: d(price), bid: nil, ask: nil}})

  # Returns once `pid` has handled every message sent to it before.
  defp sync(pid), do: :sys.get_state(pid)

  defp runners(sup), do: :"#{sup}.Runners"

  defp arm!(ctx), do: :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

  test "a fresh install journals intents as dry run and the Fake sees no place until armed",
       ctx do
    quote!(ctx.runner, "10.00")
    quote!(ctx.runner, "9.80")
    quote!(ctx.runner, "9.50")
    quote!(ctx.runner, "9.30")
    sync(ctx.runner)

    assert Fake.calls(ctx.fake, "place_") == []
    assert Fake.calls(ctx.fake, "review_") == []
    records = Broker.records(ctx.path)
    assert [_ | _] = intents = for(%{"type" => "intent"} = r <- records, do: r["mode"])
    assert Enum.all?(intents, &(&1 == "dry_run"))

    assert Enum.all?(
             for(%{"type" => "dispatch"} = r <- records, do: r["outcome"]),
             &(&1 == "not_armed")
           )

    arm!(ctx)
    quote!(ctx.runner, "8.00")
    sync(ctx.runner)
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
  end

  test "an emitted intent is journaled before the executor opens its group", ctx do
    arm!(ctx)
    quote!(ctx.runner, "10.00")
    quote!(ctx.runner, "9.80")
    sync(ctx.runner)

    records = Broker.records(ctx.path)
    emit = Enum.find_index(records, &(&1["type"] == "emit"))
    opened = Enum.find_index(records, &(&1["type"] == "intent"))
    dispatch = Enum.find(records, &(&1["type"] == "dispatch"))

    assert emit < opened
    assert Enum.at(records, emit)["intent"]["id"] == Enum.at(records, opened)["intent"]["id"]
    assert dispatch["outcome"] == "placed"
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    assert Journal.pending_intents("dip_buy-F", ctx.journal) == {:ok, []}
  end

  test "a runner killed after emitting and before the executor answers places exactly once",
       ctx do
    test = self()
    arm!(ctx)

    Fake.on_call(ctx.fake, "review_equity_order", fn _args ->
      send(test, {:reviewing, self()})
      receive do: (:go -> :answer)
    end)

    quote!(ctx.runner, "10.00")
    quote!(ctx.runner, "9.80")
    assert_receive {:reviewing, review}, 5_000
    assert {:ok, [intent]} = Journal.pending_intents("dip_buy-F", ctx.journal)

    ref = Process.monitor(ctx.runner)
    Process.exit(ctx.runner, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    send(review, :go)
    sync(runners(ctx.sup))
    [{restarted, _info}] = Strategy.Supervisor.running(ctx.sup)
    assert restarted != ctx.runner
    sync(restarted)

    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    assert Journal.pending_intents("dip_buy-F", ctx.journal) == {:ok, []}

    dispatches = for %{"type" => "dispatch"} = r <- Broker.records(ctx.path), do: r
    assert [%{"intent_id" => id, "outcome" => "duplicate"}] = dispatches
    assert id == intent.id
  end

  test "stop ends the runner and restore does not bring it back", ctx do
    assert :ok = Strategy.Supervisor.stop("dip_buy-F", ctx.opts)
    assert Strategy.Supervisor.running(ctx.sup) == []
    assert :ok = Strategy.Supervisor.restore(ctx.opts)
    assert Strategy.Supervisor.running(ctx.sup) == []
    assert {:ok, []} = Strategy.Supervisor.list(ctx.opts)
  end

  test "restore starts every added strategy that is not running", ctx do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "AAPL", "usd" => "500"})
    :ok = Journal.put_strategy(spec, ctx.journal)
    assert length(Strategy.Supervisor.running(ctx.sup)) == 1

    assert :ok = Strategy.Supervisor.restore(ctx.opts)
    assert {:ok, list} = Strategy.Supervisor.list(ctx.opts)

    assert Enum.map(list, &{&1.id, &1.status}) == [
             {"dip_buy-F", :running},
             {"dip_buy-AAPL", :running}
           ]
  end

  test "an id already added is refused", ctx do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "5"})
    assert {:error, {:already_added, "dip_buy-F"}} = Strategy.Supervisor.add(spec, ctx.opts)
  end

  test "stop terminates a runner blocked in the executor", ctx do
    test = self()
    arm!(ctx)

    Fake.on_call(ctx.fake, "review_equity_order", fn _args ->
      send(test, :reviewing)
      :hang
    end)

    quote!(ctx.runner, "10.00")
    quote!(ctx.runner, "9.80")
    assert_receive :reviewing, 5_000

    ref = Process.monitor(ctx.runner)
    assert :ok = Strategy.Supervisor.stop("dip_buy-F", ctx.opts)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert {:ok, []} = Journal.strategies(ctx.journal)
  end

  test "a crash of the runners' supervisor restores every added strategy", ctx do
    ref = Process.monitor(Process.whereis(runners(ctx.sup)))
    Process.exit(Process.whereis(runners(ctx.sup)), :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    # rest_for_one restarts the runners' supervisor and then the restorer,
    # which restores in handle_continue.
    restorer =
      Enum.find_value(Supervisor.which_children(ctx.sup), fn
        {Raxol.Broker.Strategy.Restorer, pid, _, _} -> pid
        _ -> nil
      end)

    sync(restorer)
    assert [{pid, %{id: "dip_buy-F"}}] = Strategy.Supervisor.running(ctx.sup)
    assert pid != ctx.runner
  end

  test "a second runner for one id cannot start", ctx do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
    runner = ctx.runner

    assert {:error, {:already_started, ^runner}} =
             DynamicSupervisor.start_child(runners(ctx.sup), {Raxol.Broker.Strategy.Runner, spec})

    assert [{^runner, _}] = Strategy.Supervisor.running(ctx.sup)
  end

  defp pending_runner!(ctx, extra \\ []) do
    registry = :"runner_expiry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "AAPL", "usd" => "25"})

    config =
      Keyword.merge(
        [registry: registry, journal: ctx.journal, executor: ctx.executor, clock: &Broker.t0/0],
        extra
      )

    runner =
      start_supervised!(%{
        id: registry,
        start: {Strategy.Runner, :start_link, [config, spec]}
      })

    sync(runner)
    runner
  end

  defp pending_intent!(journal, id) do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", d("1"), d("125"), provenance: :strategy, id: id)

    :ok = Journal.emit(intent, "dip_buy-AAPL", journal)
    intent
  end

  test "recovery expires emits older than the maximum age and never reviews them", ctx do
    arm!(ctx)
    intent = pending_intent!(ctx.journal, "expired-age")
    now = DateTime.add(Broker.t0(), 300_001, :millisecond)
    _runner = pending_runner!(ctx, clock: fn -> now end)

    assert Fake.calls(ctx.fake, "review_") == []
    assert Fake.calls(ctx.fake, "place_") == []
    assert Journal.pending_intents("dip_buy-AAPL", ctx.journal) == {:ok, []}

    assert [%{"intent_id" => id, "outcome" => "expired"}] =
             for %{"type" => "dispatch"} = record <- Broker.records(ctx.path), do: record

    assert id == intent.id
  end

  test "New York midnight expires even a recent emit from the previous local day", ctx do
    {clock, agent} = Broker.clock(~U[2026-10-03 03:59:59Z])
    journal = Broker.journal!(clock: clock)
    :ok = Journal.record_armed(%{"by" => "test"}, journal.journal)
    _intent = pending_intent!(journal.journal, "previous-ny-day")
    Agent.update(agent, fn _ -> ~U[2026-10-03 04:00:01Z] end)
    _runner = pending_runner!(%{ctx | journal: journal.journal}, clock: clock)

    assert [%{"outcome" => "expired"}] =
             for %{"type" => "dispatch"} = record <- Broker.records(journal.path), do: record

    assert Fake.calls(ctx.fake, "review_") == []
  end

  test "UTC midnight alone does not expire an emit in the same New York day", ctx do
    {clock, agent} = Broker.clock(~U[2026-10-03 23:59:59Z])
    journal = Broker.journal!(clock: clock)
    _intent = pending_intent!(journal.journal, "same-ny-day")
    Agent.update(agent, fn _ -> ~U[2026-10-04 00:00:01Z] end)
    _runner = pending_runner!(%{ctx | journal: journal.journal}, clock: clock)

    assert [%{"outcome" => outcome}] =
             for %{"type" => "dispatch"} = record <- Broker.records(journal.path), do: record

    # The executor is disarmed against its own journal: reaching it is
    # enough to distinguish a valid pending emit from an expired one.
    assert outcome != "expired"
  end

  test "the journal emit timestamp survives restart and the age boundary is inclusive", ctx do
    journal = Broker.journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, journal.journal)
    intent = pending_intent!(journal.journal, "fresh-boundary")
    GenServer.stop(journal.journal)
    Broker.start_journal!(journal.journal_opts)

    assert {:ok, [%{intent: ^intent, at: "2026-10-02T14:30:00.000000Z"}]} =
             Journal.pending_emissions("dip_buy-AAPL", journal.journal)

    assert {:ok, [^intent]} = Journal.pending_intents("dip_buy-AAPL", journal.journal)
    executor = Broker.executor!(journal.journal, ctx.fake)
    now = DateTime.add(Broker.t0(), 300_000, :millisecond)
    _runner =
      pending_runner!(%{ctx | journal: journal.journal, executor: executor}, clock: fn -> now end)
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
  end

  test "future emit timestamps fail closed rather than extending replay lifetime", ctx do
    arm!(ctx)
    _intent = pending_intent!(ctx.journal, "future-emit")
    now = DateTime.add(Broker.t0(), -1, :second)
    _runner = pending_runner!(ctx, clock: fn -> now end)

    assert [%{"outcome" => "expired"}] =
             for %{"type" => "dispatch"} = record <- Broker.records(ctx.path), do: record

    assert Fake.calls(ctx.fake, "review_") == []
  end

  test "missing and malformed journal emit timestamps expire without execution", ctx do
    arm!(ctx)

    for {id, timestamp} <- [{"missing-at", nil}, {"invalid-at", "not-a-date"}] do
      _intent = pending_intent!(ctx.journal, id)

      :sys.replace_state(ctx.journal, fn state ->
        [entry] = :ets.lookup(ctx.journal, {:emit, id})
        :ets.insert(ctx.journal, put_elem(entry, 4, timestamp))
        state
      end)
    end

    _runner = pending_runner!(ctx)
    assert Journal.pending_emissions("dip_buy-AAPL", ctx.journal) == {:ok, []}

    assert ["expired", "expired"] =
             for %{"type" => "dispatch", "outcome" => outcome} <- Broker.records(ctx.path),
                 do: outcome

    assert Fake.calls(ctx.fake, "review_") == []
  end

  test "a custom maximum age is enforced on retry and resume as the clock advances", ctx do
    {clock, agent} = Broker.clock(Broker.t0())
    _intent = pending_intent!(ctx.journal, "retry-expired")
    runner = pending_runner!(ctx, executor: :not_running, clock: clock, max_age_ms: 1_000)
    assert {:ok, [_]} = Journal.pending_intents("dip_buy-AAPL", ctx.journal)

    send(runner, {:pause, :dead_man})
    sync(runner)
    Agent.update(agent, &DateTime.add(&1, 1_001, :millisecond))
    send(runner, {:resume, :dead_man})
    sync(runner)
    send(runner, :retry)
    sync(runner)

    assert {:ok, []} = Journal.pending_intents("dip_buy-AAPL", ctx.journal)
    assert [%{"outcome" => "expired"}] =
             for %{"type" => "dispatch"} = record <- Broker.records(ctx.path), do: record
  end

  test "an unreadable runner clock never replays and retries only after the clock recovers", ctx do
    arm!(ctx)
    {clock, agent} = Broker.clock(:unreadable)
    intent = pending_intent!(ctx.journal, "clock-unreadable")
    runner = pending_runner!(ctx, clock: clock)

    assert Journal.pending_intents("dip_buy-AAPL", ctx.journal) == {:ok, [intent]}
    assert Fake.calls(ctx.fake, "review_") == []
    assert Enum.all?(Broker.records(ctx.path), &(&1["type"] != "dispatch"))

    Agent.update(agent, fn _ -> Broker.t0() end)
    send(runner, :retry)
    sync(runner)
    assert Journal.pending_intents("dip_buy-AAPL", ctx.journal) == {:ok, []}
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
  end

  test "runner options reject invalid maximum ages and clocks before subscribing" do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "AAPL", "usd" => "25"})
    {:ok, module, model} = Strategy.start(spec)

    for value <- [0, -1, :infinity, "300000", 1.5] do
      assert {:stop, {:invalid_max_age_ms, ^value}} =
               Strategy.Runner.init({[max_age_ms: value], spec, module, model})
    end

    for clock <- [:not_a_clock, nil, fn _argument -> Broker.t0() end] do
      assert {:stop, {:invalid_clock, ^clock}} =
               Strategy.Runner.init({[clock: clock], spec, module, model})
    end
  end
end

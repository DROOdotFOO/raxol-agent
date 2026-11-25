defmodule Raxol.Broker.Strategy.RunnerTest do
  @moduledoc """
  Runners against a real journal and an executor on the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Journal, Strategy}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    ctx = Broker.journal!()
    fake = Fake.start(quotes: %{"F" => "9.80"})
    executor = Broker.executor!(ctx.journal, fake)
    sup_name = :"strategies_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Strategy.Supervisor, name: sup_name, journal: ctx.journal, executor: executor}
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

  test "an emitted intent is journaled before the executor opens its group", ctx do
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

  test "a journal error logs its shape and prevents executor dispatch", ctx do
    sync(ctx.runner)

    :sys.replace_state(ctx.journal, fn state ->
      %{state | status: {:error, {:write_failed, %{token: "runner-secret"}}}}
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        quote!(ctx.runner, "10.00")
        quote!(ctx.runner, "9.80")
        sync(ctx.runner)
      end)

    assert log =~
             "intent not journaled, not sent: {:journal_unavailable, {:write_failed, :error}}"

    refute log =~ "runner-secret"
    assert Fake.calls(ctx.fake, "place_") == []
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

  test "concurrent adds for one id keep the journal and runner on the winning spec", ctx do
    tasks =
      for budget <- ["5", "10", "15", "20"] do
        {:ok, spec} =
          Strategy.spec("dip_buy", %{"symbol" => "AAPL", "usd" => budget}, "shared")

        Task.async(fn ->
          receive do: (:add -> {budget, Strategy.Supervisor.add(spec, ctx.opts)})
        end)
      end

    Enum.each(tasks, &send(&1.pid, :add))
    {winners, refusals} = Enum.split_with(Task.await_many(tasks), &match?({_, :ok}, &1))
    assert [{budget, :ok}] = winners
    assert Enum.all?(refusals, &match?({_, {:error, {:already_added, "shared"}}}, &1))
    assert {:ok, strategies} = Strategy.Supervisor.list(ctx.opts)

    assert %{status: :running, params: %{"usd" => ^budget}} =
             Enum.find(strategies, &(&1.id == "shared"))

    adds =
      for %{"type" => "strategy", "strategy_id" => "shared", "action" => "add"} = record <-
            Broker.records(ctx.path),
          do: record

    assert [%{"spec" => %{"params" => %{"usd" => ^budget}}}] = adds
  end

  test "stop terminates a runner blocked in the executor", ctx do
    test = self()

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
end

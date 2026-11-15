defmodule Raxol.Broker.DashboardTest do
  @moduledoc """
  The dashboard run headless (`Raxol.Headless`, ticks sent by hand) against
  a real executor and journal on the Fake, and the executor's own ASK
  timeout with no dashboard at all.
  """
  use ExUnit.Case, async: false

  alias Raxol.Broker.{Dashboard, Executor, Heartbeat, Intent, Journal}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @snapshot Path.expand("../../fixtures/dashboard/two_asks.txt", __DIR__)

  setup_all do
    unless Process.whereis(Raxol.Headless), do: start_supervised!(Raxol.Headless)
    :ok
  end

  setup do
    ctx = Broker.journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    fake = Fake.start(warnings: ["Order exceeds 5% of buying power"])
    executor = Broker.executor!(ctx.journal, fake)

    Application.put_env(:raxol_broker, Raxol.Broker.Dashboard,
      executor: executor,
      journal: ctx.journal,
      strategies: :no_strategies_here,
      client: :no_client_here
    )

    on_exit(fn -> Application.delete_env(:raxol_broker, Raxol.Broker.Dashboard) end)
    Map.merge(ctx, %{fake: fake, executor: executor})
  end

  defp dashboard! do
    id = "dash#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Raxol.Headless.start(Raxol.Broker.Dashboard,
        id: id,
        subscriptions: false,
        width: 100,
        height: 30
      )

    on_exit(fn -> Raxol.Headless.stop(id) end)
    id
  end

  defp ask!(ctx, id, qty \\ "2") do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new(qty), Decimal.new("125"),
        provenance: :strategy,
        id: id
      )

    context = %Context{quotes: %{"AAPL" => Decimal.new("125")}}
    assert {:ask, group_id, _prompts} = Executor.run(ctx.executor, intent, context)
    group_id
  end

  defp screen(id) do
    {:ok, text} = Raxol.Headless.screenshot(id)

    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp key(char), do: %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}

  # The TEA app as the SSH surface starts it for an authenticated user.
  defp operator_model(operator \\ "ssh:alice") do
    Raxol.Broker.Dashboard.init(%{
      options: [environment: :ssh, dashboard: [operator: operator]]
    })
  end

  defp press(model, keys) do
    Enum.reduce(keys, model, fn k, model ->
      model |> step(key(k)) |> settle()
    end)
  end

  defp tick(model), do: model |> step(:tick) |> settle()

  defp step(model, message) do
    {model, effects} = Dashboard.update(message, model)
    execute(effects)
    model
  end

  defp execute(effects) do
    Enum.each(effects, fn effect ->
      Raxol.Core.Runtime.Directive.Executor.execute(effect, %{pid: self(), runtime_pid: self()})
    end)
  end

  defp settle(%{in_flight: pending} = model) when map_size(pending) == 0, do: model

  defp settle(model) do
    receive do
      {:command_result, {:broker_dashboard, _operation, _ref, _result}} = message ->
        model |> step(message) |> settle()
    after
      5_000 -> flunk("dashboard operations did not settle: #{inspect(Map.keys(model.in_flight))}")
    end
  end

  defp finish_operation(model, operation) do
    if Map.has_key?(model.in_flight, operation) do
      receive do
        {:command_result, {:broker_dashboard, _operation, _ref, _result}} = message ->
          model |> step(message) |> finish_operation(operation)
      after
        5_000 -> flunk("dashboard operation did not finish: #{operation}")
      end
    else
      model
    end
  end

  defp tick_dashboard!(id) do
    session = :sys.get_state(Raxol.Headless).sessions[id]
    state = GenServer.call(session.lifecycle_pid, :get_full_state)
    dispatcher = state.dispatcher_pid
    :erlang.trace(dispatcher, true, [:receive])
    {:ok, before} = Raxol.Headless.get_model(id)
    :ok = Raxol.Headless.send_message(id, :tick)

    operations =
      [:executor, :journal, :strategies] ++ if(before.account_loaded, do: [], else: [:account])

    for operation <- operations do
      assert_receive {:trace, ^dispatcher, :receive,
                      {:command_result, {:broker_dashboard, ^operation, _ref, _result}}},
                     5_000
    end

    {:ok, _model} = Raxol.Headless.get_model(id)
    :erlang.trace(dispatcher, false, [:receive])
    :ok
  end

  test "headless shows an ASK within one frame, read-only: a sends nothing", ctx do
    dash = dashboard!()
    assert screen(dash) =~ "pending approvals (a approve, d deny, j/k move), read-only:\n  none"

    _ = ask!(ctx, "ask-approve")
    :ok = tick_dashboard!(dash)
    assert screen(dash) =~ "  ask-approve  limit buy AAPL 2 @ 125  denied in 5m"
    assert screen(dash) =~ "review_warning: Order review returned 1 warning(s)."

    :ok = Raxol.Headless.send_key(dash, "j")
    :ok = Raxol.Headless.send_key(dash, "a")
    assert screen(dash) =~ "read-only: this surface has no operator; nothing sent"
    assert Fake.calls(ctx.fake, "place_") == []
    assert [_] = Executor.parked(ctx.executor)
  end

  test "authenticated LiveView approves under its session identity", ctx do
    group = ask!(ctx, "browser-approved")
    model = Dashboard.init(%{options: [environment: :liveview, authenticated_user: "alice"]})
    model = model |> tick() |> press(["j", "a"])
    assert model.status == "approve browser-approved: placed"

    assert %{"by" => "liveview:alice", "group_id" => ^group} =
             Enum.find(Broker.records(ctx.path), &(&1["type"] == "approval"))
  end

  test "LiveView cannot obtain approval authority from dashboard options or malformed identity",
       ctx do
    _ = ask!(ctx, "browser-readonly")

    for user <- [nil, "", 123, "alice\nadmin"] do
      model =
        Dashboard.init(%{
          options: [
            environment: :liveview,
            authenticated_user: user,
            dashboard: [operator: "liveview:mallory"]
          ]
        })

      model = model |> tick() |> press(["j", "a"])
      assert model.status =~ "read-only"
    end

    assert Fake.calls(ctx.fake, "place_") == []
  end

  test "an operator approves the focused ASK into exactly one place, journaled by name", ctx do
    group_id = ask!(ctx, "ask-approve")
    model = operator_model() |> tick() |> press(["a"])
    assert model.status == "pick an approval with j/k first; nothing sent"
    assert Fake.calls(ctx.fake, "place_") == []

    model = press(model, ["j", "a"])
    assert model.status == "approve ask-approve: placed"
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]

    approval = Enum.find(Broker.records(ctx.path), &(&1["type"] == "approval"))

    assert %{"group_id" => ^group_id, "decision" => "approved", "by" => "ssh:alice"} =
             approval
  end

  test "an operator's d declines the focused ASK and nothing is placed", ctx do
    _ = ask!(ctx, "ask-decline")
    model = operator_model() |> tick() |> press(["j", "d"])

    assert model.status == "decline ask-decline: declined"
    assert Fake.calls(ctx.fake, "place_") == []
    assert Executor.parked(ctx.executor) == []
  end

  test "a focused ASK answered elsewhere is not replaced by the next one", ctx do
    first = ask!(ctx, "ask-first")
    _ = ask!(ctx, "ask-second", "3")
    model = operator_model() |> tick() |> press(["j"])
    assert model.focus == first

    :ok = Executor.decline(ctx.executor, first, "elsewhere")
    model = model |> tick() |> press(["a"])

    assert model.focus == nil
    assert model.status == "pick an approval with j/k first; nothing sent"
    assert Fake.calls(ctx.fake, "place_") == []
    assert [%{intent: %{id: "ask-second"}}] = Executor.parked(ctx.executor)
  end

  test "K kills only for an operator and only after y", ctx do
    _ = ask!(ctx, "ask-kill")

    assert operator_model(nil) |> press(["K", "y"]) |> Map.fetch!(:status) =~ "read-only"
    assert Raxol.Broker.Mode.current(ctx.journal) == :armed

    model = operator_model() |> press(["K", "x"])
    assert model.status == "kill cancelled; nothing sent"
    assert Raxol.Broker.Mode.current(ctx.journal) == :armed

    model = press(model, ["K", "y"])
    assert model.status =~ "killed:"
    assert Raxol.Broker.Mode.current(ctx.journal) == :disarmed

    halt = ctx.path |> Broker.records() |> Enum.filter(&(&1["type"] == "halt")) |> List.last()
    assert %{"reason" => "kill", "trigger" => "ssh:alice"} = halt
  end

  test "an SSH surface with no operator, and LiveView, are read-only" do
    assert operator_model(nil).operator == nil

    assert Raxol.Broker.Dashboard.init(%{options: [environment: :liveview]}).operator == nil
    assert "terminal:" <> _ = Raxol.Broker.Dashboard.init(%{options: []}).operator
  end

  test "renders two pending ASKs", ctx do
    dash = dashboard!()
    _ = ask!(ctx, "ask-one")
    _ = ask!(ctx, "ask-two", "3")
    :ok = tick_dashboard!(dash)
    :ok = Raxol.Headless.send_key(dash, "j")
    :ok = Raxol.Headless.send_key(dash, "j")

    assert screen(dash) == String.trim(File.read!(@snapshot))
  end

  test "with no dashboard, an unanswered ASK is denied by the executor as :ask_timeout", ctx do
    ctx = Map.merge(ctx, Broker.journal!())
    policy = Broker.policy("1000", "5000", ask_timeout: 1)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    executor = Broker.executor!(ctx.journal, ctx.fake, policy: policy)
    :erlang.trace(executor, true, [:receive])

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("1"), Decimal.new("125"),
        provenance: :strategy,
        id: "ask-timeout"
      )

    assert {:ask, group_id, _} =
             Executor.run(executor, intent, %Context{quotes: %{"AAPL" => Decimal.new("125")}})

    assert_receive {:trace, ^executor, :receive, {:ask_timeout, ^group_id}}, 5_000
    assert Executor.parked(executor) == []

    last =
      ctx.path |> Broker.records() |> Enum.filter(&(&1["group_id"] == group_id)) |> List.last()

    assert %{"type" => "verdict", "result" => %{"action" => "deny", "rule" => "ask_timeout"}} =
             last

    assert {:ok, [%{"outcome" => "deny ask_timeout"} | _]} = Journal.recent(ctx.journal)
    assert Fake.calls(ctx.fake, "place_") == []
  end

  defp heartbeat!(ctx) do
    name = :"dashboard_heartbeat_#{System.unique_integer([:positive])}"
    {clock, agent} = Broker.clock(0)

    pid =
      start_supervised!(
        {Heartbeat,
         name: name,
         timeout: :off,
         journal: ctx.journal,
         strategies: :no_strategies_here,
         clock: clock}
      )

    {pid, agent}
  end

  test "a held review keeps approval pending without freezing input, refresh or heartbeat", ctx do
    _group = ask!(ctx, "approve-behind-review")
    {heartbeat, clock} = heartbeat!(ctx)
    model = %{operator_model() | heartbeat: heartbeat} |> tick() |> press(["j"])
    parent = self()

    Fake.on_call(ctx.fake, "review_equity_order", fn _args ->
      send(parent, {:held_dashboard_review, self()})
      receive do: (:release_review -> :answer)
    end)

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("1"), Decimal.new("125"),
        provenance: :strategy,
        id: "held-review"
      )

    task =
      Task.async(fn ->
        Executor.run(ctx.executor, intent, %Context{quotes: %{"AAPL" => Decimal.new("125")}})
      end)

    assert_receive {:held_dashboard_review, review}, 5_000
    model = step(model, key("a"))
    assert model.status == "approve approve-behind-review: pending; outcome not yet known"
    assert Map.has_key?(model.in_flight, :answer)
    assert {^model, []} = Dashboard.update(key("a"), model)
    assert {^model, []} = Dashboard.update(key("d"), model)
    assert {^model, [%Raxol.Core.Runtime.Directive.Stop{}]} = Dashboard.update(key("q"), model)

    Agent.update(clock, fn _ -> 10 end)
    model = model |> step(:tick) |> finish_operation(:heartbeat)
    assert Heartbeat.status(heartbeat).silent_ms == 0
    assert model.status =~ "pending; outcome not yet known"
    assert Dashboard.lines(model) |> Enum.any?(&String.contains?(&1, "approve-behind-review"))
    assert Fake.calls(ctx.fake, "place_") == []

    send(review, :release_review)
    assert {:ask, _group_id, _prompts} = Task.await(task, 5_000)
    model = settle(model)
    assert model.status == "approve approve-behind-review: placed"
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]

    assert [%{"by" => "ssh:alice"}] =
             for(%{"type" => "approval"} = record <- Broker.records(ctx.path), do: record)
  end

  test "a frozen executor cannot block ticks and only one refresh or approval is in flight",
       ctx do
    _group = ask!(ctx, "frozen-executor")
    {heartbeat, clock} = heartbeat!(ctx)
    model = %{operator_model() | heartbeat: heartbeat} |> tick() |> press(["j"])
    :ok = :sys.suspend(ctx.executor)
    on_exit(fn -> if Process.alive?(ctx.executor), do: :sys.resume(ctx.executor) end)

    model = model |> step(key("a")) |> step(:tick) |> finish_operation(:heartbeat)
    answer = model.in_flight.answer
    refresh = model.in_flight.executor
    assert model.status =~ "pending"

    for key <- ["a", "d", "r"] do
      {next, effects} = Dashboard.update(key(key), model)
      assert next.in_flight.answer == answer
      assert next.in_flight.executor == refresh
      assert length(effects) == map_size(next.in_flight) - map_size(model.in_flight)
    end

    Agent.update(clock, fn _ -> 20 end)
    model = model |> step(:tick) |> finish_operation(:heartbeat)
    assert Heartbeat.status(heartbeat).silent_ms == 0
    assert model.in_flight.answer == answer
    assert model.in_flight.executor == refresh
    assert {_, []} = Dashboard.update(key("j"), model)
    assert Fake.calls(ctx.fake, "place_") == []

    :ok = :sys.resume(ctx.executor)
    model = settle(model)
    assert model.status == "approve frozen-executor: placed"
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
  end

  test "a frozen heartbeat cannot block view refresh or duplicate heartbeats", ctx do
    _group = ask!(ctx, "heartbeat-held")
    {heartbeat, _clock} = heartbeat!(ctx)
    :ok = :sys.suspend(heartbeat)
    on_exit(fn -> if Process.alive?(heartbeat), do: :sys.resume(heartbeat) end)

    model =
      %{operator_model() | heartbeat: heartbeat}
      |> step(:tick)
      |> finish_operation(:executor)

    assert [%{intent: %{id: "heartbeat-held"}}] = model.asks
    ref = model.in_flight.heartbeat
    {next, effects} = Dashboard.update(:tick, model)
    assert next.in_flight.heartbeat == ref
    assert length(effects) == map_size(next.in_flight) - map_size(model.in_flight)
    assert {_, []} = Dashboard.update(key("j"), model)

    :ok = :sys.resume(heartbeat)
    _model = settle(model)
  end

  test "a kill waiting on a frozen journal stays tracked without blocking the dashboard", ctx do
    model = operator_model()
    :ok = :sys.suspend(ctx.journal)
    on_exit(fn -> if Process.whereis(ctx.journal), do: :sys.resume(ctx.journal) end)

    model = model |> step(key("K")) |> step(key("y"))
    assert model.status == "kill pending; outcome not yet known"
    ref = model.in_flight.kill
    {next, []} = Dashboard.update(key("a"), model)
    assert next.in_flight.kill == ref
    assert {_, [%Raxol.Core.Runtime.Directive.Stop{}]} = Dashboard.update(key("q"), model)

    :ok = :sys.resume(ctx.journal)
    model = settle(model)
    assert model.status =~ "killed:"
    assert Raxol.Broker.Mode.current(ctx.journal) == :disarmed
  end

  test "a frozen account client leaves refresh, heartbeat and input responsive", ctx do
    client =
      start_supervised!({Raxol.Broker.MCP.Client, Fake.client_opts(ctx.fake)})

    assert {:ok, [_ | _]} = Raxol.Broker.MCP.Client.list_tools(client)
    {heartbeat, _clock} = heartbeat!(ctx)
    :ok = :sys.suspend(client)
    on_exit(fn -> if Process.alive?(client), do: :sys.resume(client) end)

    model =
      %{operator_model() | client: client, heartbeat: heartbeat}
      |> step(:tick)
      |> finish_operation(:heartbeat)
      |> finish_operation(:executor)

    account = model.in_flight.account
    assert model.mode == :armed or Map.has_key?(model.in_flight, :journal)
    assert {_, []} = Dashboard.update(key("j"), model)
    {next, _effects} = Dashboard.update(key("r"), model)
    assert next.in_flight.account == account
    assert Heartbeat.status(heartbeat).silent_ms == 0

    :ok = :sys.resume(client)
    model = settle(model)
    assert Enum.any?(model.account, &String.starts_with?(&1, "account FAKE-0001"))
  end
end

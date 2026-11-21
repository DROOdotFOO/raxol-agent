defmodule Raxol.Broker.DailyBaselineConcurrencyTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{DailyBaseline, Journal}
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @day ~U[2026-10-02 04:00:00Z]

  defp worker!(journal, client, clock) do
    owner = self()
    id = System.unique_integer([:positive])

    start_supervised!(
      Supervisor.child_spec(
        {DailyBaseline,
         journal: journal,
         client: client,
         clock: clock,
         account: "FAKE-0001",
         schedule: fn delay -> send(owner, {:scheduled, self(), delay}) end},
        id: {DailyBaseline, id},
        restart: :temporary
      )
    )
  end

  defp gated_fake! do
    owner = self()
    fake = Fake.start(portfolio: %{"total_value" => "1000", "currency" => "USD"})

    Fake.on_call(fake, "get_portfolio", fn _args ->
      send(owner, {:reading, self()})

      receive do
        {:answer, value} ->
          {:result,
           %{
             "content" => [
               %{
                 "type" => "text",
                 "text" =>
                   Jason.encode!(%{
                     "data" => %{"total_value" => value, "currency" => "USD"}
                   })
               }
             ]
           }}
      end
    end)

    client = start_supervised!({Client, Fake.client_opts(fake)})
    {fake, client}
  end

  test "late, cross-day and backwards-clock completions cannot capture or later revive" do
    for {started, completed} <- [
          {@day, DateTime.add(@day, 60)},
          {@day, DateTime.add(@day, 86_400)},
          {DateTime.add(@day, 1), @day}
        ] do
      owner = self()
      fake = Fake.start(portfolio: %{"total_value" => "1000", "currency" => "USD"})

      Fake.on_call(fake, "get_portfolio", fn _ ->
        send(owner, {:reading, self()})
        receive do: (:answer -> :continue)
      end)

      id = System.unique_integer([:positive])

      client =
        start_supervised!(
          Supervisor.child_spec({Client, Fake.client_opts(fake)}, id: {Client, id})
        )

      {clock, agent} = Broker.clock(started)
      ctx = Broker.journal!(clock: clock)
      worker = worker!(ctx.journal, client, clock)
      assert_receive {:reading, exchange}, 5_000
      %{task: {reader, _ref, _start}} = :sys.get_state(worker)
      Agent.update(agent, fn _ -> completed end)
      send(exchange, :answer)
      assert_receive {:scheduled, ^worker, _delay}, 5_000
      assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
      assert Broker.records(ctx.path) == []
      send(worker, {:baseline_read, reader, {:ok, Broker.d("1000"), started}})
      :sys.get_state(worker)
      assert Broker.records(ctx.path) == []
    end
  end

  test "two simultaneous captures cannot replace the first durable baseline" do
    {fake, client} = gated_fake!()

    other_client =
      start_supervised!(
        Supervisor.child_spec({Client, Fake.client_opts(fake)}, id: {Client, make_ref()})
      )

    {clock, _agent} = Broker.clock(@day)
    ctx = Broker.journal!(clock: clock)
    first = worker!(ctx.journal, client, clock)
    assert_receive {:reading, exchange1}, 5_000
    second = worker!(ctx.journal, other_client, clock)
    assert_receive {:reading, exchange2}, 5_000

    send(exchange1, {:answer, "1000"})
    assert_receive {:scheduled, ^first, _delay}, 5_000
    send(exchange2, {:answer, "900"})
    assert_receive {:scheduled, ^second, _delay}, 5_000
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, Broker.d("1000")}
    assert [%{"type" => "day_baseline", "value" => "1000"}] = Broker.records(ctx.path)
  end

  test "journal disappearing during the live read never leaves a volatile baseline" do
    {_fake, client} = gated_fake!()
    {clock, _agent} = Broker.clock(@day)
    ctx = Broker.journal!(clock: clock)
    worker = worker!(ctx.journal, client, clock)
    monitor = Process.monitor(worker)
    assert_receive {:reading, exchange}, 5_000
    GenServer.stop(ctx.journal)
    send(exchange, {:answer, "1000"})
    assert_receive {:DOWN, ^monitor, :process, ^worker, {:journal_unavailable, _reason}}, 5_000
    Broker.start_journal!(ctx.journal_opts)
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
    assert Broker.records(ctx.path) == []
  end

  test "stopping the collector terminates its outstanding read and cannot publish late" do
    {_fake, client} = gated_fake!()
    {clock, _agent} = Broker.clock(@day)
    ctx = Broker.journal!(clock: clock)
    worker = worker!(ctx.journal, client, clock)
    assert_receive {:reading, exchange}, 5_000
    %{task: {reader, _ref, _started}} = :sys.get_state(worker)
    monitor = Process.monitor(reader)
    :ok = GenServer.stop(worker)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 5_000
    send(exchange, {:answer, "1000"})
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
    assert Broker.records(ctx.path) == []
  end
end

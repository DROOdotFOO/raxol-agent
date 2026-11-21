defmodule Raxol.Broker.CollectorHandoffTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{CollectorHandoff, Journal}
  alias Raxol.Broker.MCP.{Client, Fake}

  setup do
    id = System.unique_integer([:positive])
    directory = Path.join(System.tmp_dir!(), "broker-drain-#{id}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    journal = :"drain_journal_#{id}"
    client = :"drain_client_#{id}"
    fake = Fake.start(trade_approvals: true)

    children = [
      {Journal, [name: journal, path: Path.join(directory, "journal")]},
      {Client, Fake.client_opts(fake, name: client)}
    ]

    root =
      start_supervised!(%{
        id: {:collector, id},
        restart: :temporary,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      })

    {:ok, _} = Client.list_tools(client, 5_000)
    {:ok, directory: directory, root: root, client: client, journal: journal, fake: fake}
  end

  test "quiescence acknowledges only after client and journal have stopped", ctx do
    request(ctx.directory)
    client = GenServer.whereis(ctx.client)
    journal = GenServer.whereis(ctx.journal)

    assert :quiesced =
             CollectorHandoff.quiesce(ctx.directory, ctx.root,
               client: ctx.client,
               journal: ctx.journal
             )

    refute Process.alive?(client)
    refute Process.alive?(journal)
    refute Process.alive?(ctx.root)

    assert %{
             "status" => "quiesced",
             "client_stopped" => true,
             "journal_closed" => true,
             "nonce" => nonce
           } = acknowledgement(ctx.directory)

    assert nonce == String.duplicate("a", 48)
  end

  test "an armed journal is not stopped or left suspended", ctx do
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    request(ctx.directory)

    assert :blocked =
             CollectorHandoff.quiesce(ctx.directory, ctx.root,
               client: ctx.client,
               journal: ctx.journal
             )

    assert {:ok, _} = Client.list_tools(ctx.client, 5_000)
    assert {:ok, :armed, _} = Journal.mode(ctx.journal)
    assert %{"status" => "blocked", "client_stopped" => false} = acknowledgement(ctx.directory)
  end

  test "a signal without a valid owner request cannot stop the collector", ctx do
    assert :ignored =
             CollectorHandoff.quiesce(ctx.directory, ctx.root,
               client: ctx.client,
               journal: ctx.journal
             )

    request(ctx.directory)
    File.chmod!(Path.join(ctx.directory, "handoff-request.json"), 0o666)

    assert :ignored =
             CollectorHandoff.quiesce(ctx.directory, ctx.root,
               client: ctx.client,
               journal: ctx.journal
             )

    assert {:ok, _} = Client.list_tools(ctx.client, 5_000)
    assert :ok = Journal.status(ctx.journal)
    refute File.exists?(Path.join(ctx.directory, "handoff-quiesced.json"))
  end

  test "expired and wrong-process requests leave the read client usable", ctx do
    for override <- [%{"deadline" => "2000-01-01T00:00:00Z"}, %{"process_id" => "1"}] do
      request(ctx.directory, override)

      assert :ignored =
               CollectorHandoff.quiesce(ctx.directory, ctx.root,
                 client: ctx.client,
                 journal: ctx.journal
               )

      assert {:ok, _} = Client.list_tools(ctx.client, 5_000)
      assert :ok = Journal.status(ctx.journal)
    end
  end

  test "an acknowledgement write failure does not kill a blocked collector", ctx do
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    request(ctx.directory)
    File.write!(Path.join(ctx.directory, "handoff-quiesced.json.tmp"), "existing")

    ExUnit.CaptureLog.capture_log(fn ->
      assert :blocked =
               CollectorHandoff.quiesce(ctx.directory, ctx.root,
                 client: ctx.client,
                 journal: ctx.journal
               )
    end)

    assert {:ok, _} = Client.list_tools(ctx.client, 5_000)
    assert {:ok, :armed, _} = Journal.mode(ctx.journal)
    refute File.exists?(Path.join(ctx.directory, "handoff-quiesced.json"))
  end

  test "a refused real-Fake bearer blocks drain without closing the journal", ctx do
    :ok = Fake.accept(ctx.fake, ["different-fixture-bearer"])
    assert {:error, _} = Client.call(ctx.client, "get_accounts", %{}, 5_000)
    request(ctx.directory)

    assert :blocked =
             CollectorHandoff.quiesce(ctx.directory, ctx.root,
               client: ctx.client,
               journal: ctx.journal
             )

    assert :ok = Journal.status(ctx.journal)
    assert %{"status" => "blocked", "client_stopped" => false} = acknowledgement(ctx.directory)
    assert Process.alive?(GenServer.whereis(ctx.client))
  end

  test "an abandoned drained caller exits after its deadline and recovery grace", ctx do
    request(ctx.directory)

    assert :quiesced =
             CollectorHandoff.quiesce(ctx.directory, ctx.root,
               client: ctx.client,
               journal: ctx.journal
             )

    expired = DateTime.utc_now() |> DateTime.add(-661, :second) |> DateTime.to_iso8601()
    report = Map.put(acknowledgement(ctx.directory), "deadline", expired)
    File.write!(Path.join(ctx.directory, "handoff-quiesced.json"), Jason.encode!(report))
    {pid, monitor} = spawn_monitor(fn -> CollectorHandoff.wait_for_unload(ctx.directory) end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :collector_handoff_abandoned}
  end

  defp request(directory, override \\ %{}) do
    fields =
      Map.merge(
        %{
          "process_id" => System.pid(),
          "nonce" => String.duplicate("a", 48),
          "deadline" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()
        },
        override
      )

    path = Path.join(directory, "handoff-request.json")
    File.write!(path, Jason.encode!(fields))
    File.chmod!(path, 0o600)
  end

  defp acknowledgement(directory) do
    directory |> Path.join("handoff-quiesced.json") |> File.read!() |> Jason.decode!()
  end
end

# Launched only by scripts/test_handoff.py, with an isolated journal and no store.
[role] = System.argv()
{:ok, _} = Application.ensure_all_started(:raxol_broker)
Logger.configure(level: :error)
owner = self()

{:ok, _} =
  System.trap_signal(:sigterm, fn ->
    send(owner, :stop)
    System.stop(0)
    :ok
  end)

{:ok, _} =
  System.trap_signal(:sigusr2, fn ->
    send(owner, :cooperative_drain)
    :ok
  end)

directory = System.fetch_env!("FIXTURE_DIRECTORY")

alias Raxol.Broker.{DailyBaseline, Executor, Journal, MarketCalendar, PolicyFile}
alias Raxol.Broker.MCP.{Client, Fake}
day = MarketCalendar.day_start(DateTime.utc_now())

if role == "collector" and File.exists?(Path.join(directory, "started")) do
  temporary = Path.join(directory, "status.json.tmp")
  File.write!(temporary, Jason.encode!(%{status: "starting", process_id: System.pid()}))
  File.chmod!(temporary, 0o600)
  File.rename!(temporary, Path.join(directory, "status.json"))
  File.write!(Path.join(directory, "recovering"), "starting")

  receive do
    :cooperative_drain -> :ok
    :stop -> System.halt(0)
  end
end

clock = fn -> day end
fake = Fake.start(trade_approvals: true)
{:ok, policy} = PolicyFile.new(Decimal.new("25"), Decimal.new("100"))

options = [
  journal: [path: Path.join(directory, "journal"), clock: clock],
  client: Keyword.put(Fake.client_opts(fake), :name, Client),
  daily_baseline: [clock: clock, schedule: fn _ -> send(owner, :baseline_attempt) end]
]

options =
  if role == "collector" do
    # Explicitly start the same real worker without installing an executor.
    options
  else
    Keyword.put(options, :executor,
      session: Fake.session(fake),
      policy: policy,
      account_number: "FAKE-0001",
      clock: clock
    )
  end

{:ok, root} = Raxol.Broker.Supervisor.start_link(options)

if role == "collector" do
  {:ok, _} =
    Supervisor.start_child(
      root,
      {DailyBaseline,
       [
         account: "FAKE-0001",
         journal: Journal,
         client: Client,
         clock: clock,
         schedule: fn _ -> send(owner, :baseline_attempt) end
       ]}
    )
else
  :ok = Executor.await_port(Executor, 10_000)
end

receive do
  :baseline_attempt -> :ok
after
  10_000 -> raise "fixture baseline worker did not finish"
end

{:ok, %Decimal{}} = Journal.day_baseline("FAKE-0001", day)
:ok = Journal.verify()
:disarmed = Raxol.Broker.Mode.current()
{:ok, _} = Client.list_tools(Client, 5_000)
if role == "fail", do: raise("isolated startup failure after journal ownership")

report = %{
  status: "running",
  mode: "disarmed",
  observed_at: DateTime.to_iso8601(DateTime.utc_now()),
  process_id: if(role == "bad_pid", do: "1", else: System.pid()),
  client_status: "ready",
  credential_persistence_pending: false,
  executor_started: role != "collector",
  strategies_started: false,
  baseline_verified: true,
  handoff_protocol: 1,
  executor_port_ready: role != "collector",
  nonce:
    if(role in ["bad_nonce", "cleanup_bad_nonce"],
      do: "wrong-fixture-nonce",
      else: System.get_env("BROKER_HANDOFF_NONCE")
    )
}

path =
  if role == "collector",
    do: Path.join(directory, "status.json"),
    else: System.fetch_env!("BROKER_HANDOFF_READY")

if role in ["cleanup_ready", "cleanup_bad_nonce"] do
  File.write!(Path.join(directory, "handoff-request.json"), "invalid fixture cleanup document")
end

File.write!(path <> ".tmp", Jason.encode!(report))
File.chmod!(path <> ".tmp", 0o600)
File.rename!(path <> ".tmp", path)
if role == "collector", do: File.write!(Path.join(directory, "started"), "ready")

receive do
  :cooperative_drain ->
    File.write!(Path.join(directory, "stopping"), "drain_requested")

    receive do
      :cooperative_drain -> :ok
      :stop -> System.halt(0)
    end

    :quiesced = Raxol.Broker.CollectorHandoff.quiesce(directory, root)

    Raxol.Broker.CollectorHandoff.wait_for_unload(directory)

  :stop ->
    :ok
end

if Process.alive?(root), do: Supervisor.stop(root)

defmodule Raxol.Web3.Backend.CantonHarness do
  @moduledoc false
  # Fixtures and handle builders shared by the canton test files.

  alias Raxol.Web3.Backend.Canton

  @fixtures Path.expand("../../fixtures/canton", __DIR__)

  # The bootstrap update, migration 0, offset 1. Immutable by construction, so a
  # live test can name it and keep naming it.
  @update_id "1220c7d293ea23275dcc7bfef9d47fa10e76477d26c93db4074ee5dff5e2cd8a5680"

  # Recorded from the live API on 2026-09-14 and trimmed. `dso.json` keeps two
  # of the fifteen super-validator node states (the migration id is read from
  # them) and drops the amulet and DSO rule bodies; `update.json` keeps both
  # root events and drops their Daml create and choice arguments. A fixture is
  # not a mock: it is what the upstream said, and it is the only thing that
  # makes "the shape changed" a red test rather than a production surprise.
  def fixture(name), do: File.read!(Path.join(@fixtures, "#{name}.json"))

  # Both limiters get room on purpose. Every test here talks to the same two
  # origins, so the shared bucket and breaker would couple unrelated tests
  # through them; they are `Raxol.Web3.HTTPTest`'s subject. One test asks for
  # `metered: true` instead, so the backend's own seed is exercised rather than
  # read out of module data and compared with itself.
  def unmetered(metered?) do
    breaker_and_dns() ++
      if metered?,
        do: [],
        else: [rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0]]
  end

  def breaker_and_dns do
    [
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  def serving(routes) do
    fn _vetted, request, _opts ->
      send(self(), {:request, request})

      path = request.path |> String.split("?") |> hd()

      case Map.fetch(routes, path) do
        {:ok, %{} = pages} -> {:ok, %{status: 200, headers: [], body: page_for(pages, request)}}
        {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
        {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
        :error -> {:ok, %{status: 404, headers: [], body: ~s({"error":"not found"})}}
      end
    end
  end

  # A route carrying several recorded pages of one endpoint, told apart by the
  # `after` the upstream itself minted. A request for a page nobody recorded
  # raises here rather than being answered with the wrong one.
  def page_for(pages, request), do: Map.fetch!(pages, Jason.decode!(request.body)["after"])

  def handle(routes, opts \\ []) do
    http_opts =
      [{:exchange, serving(routes)} | unmetered(Keyword.get(opts, :metered, false))] ++
        Keyword.take(opts, [:headers])

    {:ok, handle} =
      Canton.new(
        Keyword.get(opts, :chain_ref, "canton:global"),
        Keyword.merge(
          [http_opts: http_opts, cache: Keyword.get(opts, :cache, false)],
          Keyword.take(opts, [:ccscan_key, :migration_id, :scan_url])
        )
      )

    handle
  end

  def state(handle), do: elem(handle, 1)

  # The keyless Splice Scan surface, as recorded. Every test that is not about a
  # refusal starts from this map and overrides one row.
  def scan_routes do
    %{
      "/v0/round-of-latest-data" => fixture("round_of_latest_data"),
      "/v0/dso" => fixture("dso"),
      "/v0/state/acs/snapshot-timestamp" => fixture("acs_snapshot_timestamp"),
      "/v0/splice-instance-names" => ~s({"amulet_name":"Canton Coin","amulet_name_acronym":"CC"}),
      "/v0/holdings/summary" => fixture("holdings_summary"),
      "/v0/holdings/state" => fixture("holdings_state"),
      "/v0/updates/#{@update_id}" => fixture("update")
    }
  end

  def drain(acc \\ []) do
    receive do
      {:request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def requested_paths, do: Enum.map(drain(), & &1.path)
end

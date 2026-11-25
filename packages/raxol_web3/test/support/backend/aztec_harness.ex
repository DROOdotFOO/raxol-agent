defmodule Raxol.Web3.Backend.AztecHarness do
  @moduledoc false
  # Fixtures and handle builders shared by the aztec test files.

  alias Raxol.Web3.Backend.Aztec

  @fixtures Path.expand("../../fixtures/aztec", __DIR__)

  @chain "aztec:mainnet"

  # Recorded from the live API on 2026-09-14, trimmed to two items per array.
  # A fixture is not a mock: it is what the upstream actually said, and it is
  # the only thing that makes "the shape changed" a red test rather than a
  # production surprise, since nothing specifies these response bodies.
  def fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Both limiters are given room on purpose. The seeded rate limit is a
  # labelled guess about somebody else's service and the breaker is the
  # router's subject, so coupling every test in this file to them through one
  # shared origin would buy nothing. The revocation tests below set their own.
  def unmetered do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  # Routes on the endpoint rather than the whole path, so a route map reads as
  # the API surface and stays the same whether the credential prefix is the
  # hosted temporary one or a self-hosted instance's. The hostname is recorded
  # alongside, because "which origin answered" is the whole question in a
  # failover test.
  def serving(routes) do
    fn vetted, request, _opts ->
      endpoint = endpoint(request.path)
      send(self(), {:request, vetted.hostname, endpoint})

      case Map.fetch(routes, endpoint) do
        {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
        {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
        :error -> {:ok, %{status: 404, headers: [], body: fixture("revoked_prefix_404.txt")}}
      end
    end
  end

  def endpoint(path) do
    case String.split(path, "/l2", parts: 2) do
      [_prefix, rest] -> "/l2" <> rest
      [whole] -> whole
    end
  end

  def handle(routes, opts \\ []) do
    http_opts = [{:exchange, serving(routes)} | unmetered()]

    {:ok, handle} =
      Aztec.new(@chain,
        base_url: Keyword.get(opts, :base_url),
        http_opts: http_opts,
        # Off by default, and not for convenience. The cache is per node and
        # keyed by origin plus endpoint, so every test here asking the hosted
        # instance the same question would share one entry and the first to run
        # would answer for the rest. The cache tests below own their origins.
        cache: Keyword.get(opts, :cache, false)
      )

    handle
  end

  def state(handle), do: elem(handle, 1)

  def own_origin,
    do: "https://chicmoz-#{System.unique_integer([:positive])}.example.org/v1/local"

  def drain(acc \\ []) do
    receive do
      {:request, host, endpoint} -> drain([{host, endpoint} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def endpoints, do: Enum.map(drain(), &elem(&1, 1))

  def hosts, do: Enum.map(drain(), &elem(&1, 0))

  def patched(name, changes) do
    name |> fixture() |> Jason.decode!() |> Map.merge(changes) |> Jason.encode!()
  end
end

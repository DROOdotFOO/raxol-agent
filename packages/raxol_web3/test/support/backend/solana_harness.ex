defmodule Raxol.Web3.Backend.SolanaHarness do
  @moduledoc false
  # Fixtures and handle builders shared by the solana test files.

  alias Raxol.Web3.Backend.Solana

  @fixtures Path.expand("../../fixtures/solana", __DIR__)

  # Recorded from the live APIs on 2026-09-14. A fixture is not a mock: it is
  # what the upstream actually said, replayed through the `:exchange` seam
  # because the vet refuses loopback and no local endpoint is reachable through
  # the pipeline. It is the only thing that makes "the shape changed" a red test
  # rather than a production surprise, and neither upstream publishes a spec for
  # what these calls return.
  def fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Both limiters are given room on purpose: every test here talks to one
  # origin per source, so the shared bucket and breaker would couple unrelated
  # tests through it. They are `Raxol.Web3.HTTPTest`'s subject.
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

  # An SSE body in the framing SQD actually uses: one `event: message` line,
  # then `data:` with the space, then a blank line.
  def sse(payload) do
    envelope = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{"content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]}
    }

    "event: message\ndata: " <> Jason.encode!(envelope) <> "\n\n"
  end

  def sse_error(payload) do
    envelope = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
        "isError" => true
      }
    }

    "event: message\ndata: " <> Jason.encode!(envelope) <> "\n\n"
  end

  # Routes an MCP `tools/call` by tool name and a JSON-RPC call by method, so
  # one arrangement exercises either source. `getSlot` is routed by its
  # commitment as well, because the whole point of that call is that the two
  # commitments answer different numbers.
  def serving(responses) do
    fn _vetted, request, _opts ->
      send(self(), {:request, request})
      body = Jason.decode!(request.body)

      case Map.fetch(responses, route(body)) do
        {:ok, {status, payload}} -> {:ok, %{status: status, headers: [], body: payload}}
        {:ok, payload} -> {:ok, %{status: 200, headers: [], body: payload}}
        :error -> {:ok, %{status: 404, headers: [], body: ~s({"unrouted":true})}}
      end
    end
  end

  # `portal_get_head`, `getSlot` and `getSignaturesForAddress` are routed by
  # their one distinguishing argument, because the whole point of each is that
  # two calls answer two different things and a router keyed on the name alone
  # would hide that.
  def route(%{"method" => "tools/call", "params" => %{"name" => "portal_get_head"} = params}),
    do: "portal_get_head:" <> get_in(params, ["arguments", "type"])

  def route(%{"method" => "tools/call", "params" => %{"name" => name}}), do: name
  def route(%{"method" => "getSlot", "params" => [%{"commitment" => c}]}), do: "getSlot:" <> c

  def route(%{
        "method" => "getSignaturesForAddress",
        "params" => [_pubkey, %{"before" => _sig}]
      }),
      do: "getSignaturesForAddress:before"

  def route(%{"method" => method}), do: method

  # The catalog resolution runs before every SQD read, so it is merged in unless
  # a test is about it.
  def catalog, do: %{"portal_list_networks" => fixture("sqd_list_networks.sse")}

  def handle(source, responses, opts) do
    http_opts = [{:exchange, serving(responses)} | unmetered()] ++ Keyword.take(opts, [:headers])

    {:ok, handle} =
      Solana.new(
        Keyword.get(opts, :chain_ref, "solana:mainnet"),
        [
          source: source,
          http_opts: http_opts,
          # Off by default, and not for convenience. The cache is per node and
          # keyed by origin plus fragment, so every test asking the same source
          # the same question would share one entry and the first to run would
          # answer for the rest. The cache tests below use their own origins.
          cache: Keyword.get(opts, :cache, false)
        ] ++ Keyword.take(opts, [:network, :url])
      )

    handle
  end

  def sqd(responses, opts \\ []),
    do: handle(:sqd, Map.merge(catalog(), responses), opts)

  def rpc(responses, opts \\ []), do: handle(:rpc, responses, opts)

  def state(handle), do: elem(handle, 1)

  def drain(acc \\ []) do
    receive do
      {:request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def requested_tools do
    Enum.map(drain(), fn request ->
      request.body |> Jason.decode!() |> route()
    end)
  end

  def requested_bodies do
    Enum.map(drain(), &Jason.decode!(&1.body))
  end
end

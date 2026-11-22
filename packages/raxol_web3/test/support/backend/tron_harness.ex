defmodule Raxol.Web3.Backend.TronHarness do
  @moduledoc false
  # Fixtures, a recorded MCP seam and handle builders for the Tron tests.

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Era
  alias Raxol.Web3.Backend.Tron

  @fixtures Path.expand("../../fixtures/tron", __DIR__)

  # Recorded from the live upstreams on 2026-09-14 and trimmed to two items per
  # page. A fixture is not a mock: it is what the upstream actually said, which
  # is the only thing that makes "the shape changed" a red test rather than a
  # production surprise. None of these upstreams publishes a schema for its
  # tool results, and one of them publishes a schema its own tool violates.
  def fixture(name), do: File.read!(Path.join(@fixtures, name))

  # SQD Portal is one server behind both this backend and
  # `Raxol.Web3.Backend.Solana`, and it answers an unknown network the same
  # way whichever VM asked. The recorded refusal is read from the Solana
  # directory rather than copied into this one, so both backends classify
  # one recording.
  def sqd_fixture(name) do
    @fixtures |> Path.join("../solana") |> Path.join(name) |> File.read!()
  end

  # Both limiters are given room, and the resolver answers without DNS. Every
  # test here talks to one of three real hostnames, so a shared bucket or
  # breaker would couple unrelated tests through it.
  def unmetered do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: &stub_resolver/2
    ]
  end

  def stub_resolver(_charlist, :inet), do: {:ok, [{93, 184, 216, 34}]}
  def stub_resolver(_charlist, :inet6), do: {:ok, []}

  # One seam for three session models. It routes on the JSON-RPC method, and on
  # the tool name for a `tools/call`, so the same arrangement drives a stateless
  # POST and a legacy handshake plus session.
  #
  # The recorded envelope is re-stamped with the id the client actually sent:
  # answering a stale id would leave the request pending and the test would
  # time out instead of exercising the mapping.
  def seam(routes, opts \\ []) do
    context = %{
      routes: routes,
      owner: self(),
      # Measured 2026-09-14: TronGrid frames `data: {...}` with the space and
      # TronScan frames `data:{...}` without one, so a strict parser breaks on
      # one of them and each source replays its own framing here.
      spacer: Keyword.get(opts, :spacer, " "),
      initialize: Keyword.get(opts, :initialize, "trongrid_initialize.json"),
      session: Keyword.get(opts, :session, "11111111-2222-3333-4444-555555555555"),
      hold_ms: Keyword.get(opts, :hold_ms, 0)
    }

    fn _vetted, request, _exchange_opts ->
      request.body |> IO.iodata_to_binary() |> Jason.decode!() |> answer(context)
    end
  end

  # The transport probes an origin it holds no era verdict for with
  # `server/discover`, and all three of these upstreams answer it the way a
  # legacy server does: JSON-RPC -32601. Answering it here rather than
  # pre-seeding alone is what keeps a cache miss -- a fresh table, an expired
  # TTL, a session-rejected re-probe -- a mapped verdict instead of a crash in
  # the seam.
  def answer(%{"method" => "server/discover", "id" => id}, _context) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def answer(%{"method" => "initialize", "id" => id}, context) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"content-type", "application/json"},
         {"mcp-session-id", context.session}
       ],
       body: restamp(fixture(context.initialize), id)
     }}
  end

  def answer(%{"method" => "notifications/initialized"}, _context) do
    {:ok, %{status: 202, headers: [{"content-type", "application/json"}], body: ""}}
  end

  def answer(%{"method" => "tools/call"} = envelope, context) do
    %{"id" => id, "params" => %{"name" => tool, "arguments" => arguments}} = envelope
    reference = make_ref()
    send(context.owner, {:called, tool, arguments, reference})
    hold(context.owner, reference, context.hold_ms)

    routed(route(context.routes, tool, arguments), tool, id, context)
  end

  # What a route resolves to: a client-level failure, a bare status, a recorded
  # body, or the name of a recording to read.
  def routed({:ok, {:error, reason}}, _tool, _id, _context), do: {:error, reason}

  def routed({:ok, {:status, status}}, _tool, _id, _context) do
    {:ok, %{status: status, headers: [], body: ""}}
  end

  def routed({:ok, {:body, body}}, _tool, id, context), do: streamed(body, id, context)

  def routed({:ok, name}, _tool, id, context) when is_binary(name) do
    name |> fixture() |> streamed(id, context)
  end

  def routed(:error, tool, _id, _context) do
    flunk("no recorded response for tool #{tool}")
  end

  def streamed(body, id, context) do
    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "text/event-stream"}],
       body: frame(body, id, context.spacer)
     }}
  end

  # Only a `tools/call` is bracketed, so the handshake does not appear in the
  # concurrency log. The sleep is what makes an overlap observable at all.
  def hold(_owner, _reference, 0), do: :ok

  def hold(owner, reference, ms) do
    Process.sleep(ms)
    send(owner, {:returned, reference})
  end

  # A route may be a fixture name or a function of the arguments, because one
  # read can call one tool twice with different arguments and the whole point
  # of the second call is that it lands on a different block.
  def route(routes, tool, arguments) do
    case Map.fetch(routes, tool) do
      {:ok, fun} when is_function(fun, 1) -> {:ok, fun.(arguments)}
      other -> other
    end
  end

  def sampled_block(%{"id_or_num" => _number}), do: "trongrid_block_earlier.sse"
  def sampled_block(_head), do: "trongrid_block.sse"

  def frame(recorded, id, spacer) do
    "event: message\ndata:" <> spacer <> restamp(recorded, id) <> "\n\n"
  end

  def restamp(recorded, id) do
    recorded
    |> payload()
    |> Jason.decode!()
    |> Map.put("id", id)
    |> Jason.encode!()
  end

  def payload(recorded) do
    case Regex.run(~r/^data:[ ]?(.*)$/m, recorded) do
      [_line, data] -> data
      nil -> recorded
    end
  end

  def account_fixture_with_balance(value) do
    envelope = fixture("trongrid_account_info.sse") |> payload() |> Jason.decode!()
    result = envelope["result"]
    content = result["content"]
    inner = content |> hd() |> Map.fetch!("text") |> Jason.decode!()

    changed =
      Map.update!(inner, "data", fn [account | rest] ->
        [Map.put(account, "balance", value) | rest]
      end)

    changed_content =
      List.update_at(content, 0, &Map.put(&1, "text", Jason.encode!(changed)))

    changed_result =
      result
      |> Map.put("content", changed_content)
      |> Map.put("structuredContent", changed)

    envelope |> Map.put("result", changed_result) |> Jason.encode!()
  end

  def stateful(source, routes, opts \\ []) do
    eras = :ets.new(:eras, [:public, :set])
    breakers = Keyword.get_lazy(opts, :breakers, fn -> :ets.new(:breakers, [:public, :set]) end)
    Era.remember(eras, Era.key(URI.new!(Tron.sources()[source].url)), :legacy)

    seam_opts =
      opts
      |> Keyword.put(:spacer, if(source == :tronscan, do: "", else: " "))
      |> Keyword.put(:initialize, "#{source}_initialize.json")

    # `:restart` is `:temporary` for the tests that kill the client on
    # purpose. Under the default the test supervisor restarts it, and the
    # replacement races teardown of the ETS tables above, which is noise about
    # the harness rather than about the backend.
    spec =
      Tron.client_spec(source,
        name: :"tron_#{source}_#{System.unique_integer([:positive])}",
        exchange: seam(routes, seam_opts),
        tables: %{eras: eras, breakers: breakers},
        resolver: &stub_resolver/2
      )
      |> Map.put(:restart, Keyword.get(opts, :restart, :permanent))

    client = start_supervised!(spec)
    await_ready(client)

    {:ok, handle} =
      Tron.new(source, client: client, cache: Keyword.get(opts, :cache, false))

    handle
  end

  # The handshake is asynchronous: `initialize` is dispatched from `init/1` and
  # its reply arrives as a message, so a call issued immediately answers
  # `{:not_ready, :initializing}`. Waiting here rather than retrying inside the
  # backend is deliberate: a client that is not ready yet is the client's
  # business, and a retry in a read would hide a stuck handshake.
  def await_ready(client, remaining \\ 400) do
    case Client.status(client) do
      %{status: :ready} ->
        :ok

      %{status: status} when remaining == 0 ->
        flunk("client never became ready, stuck in #{inspect(status)}")

      _still_starting ->
        Process.sleep(5)
        await_ready(client, remaining - 1)
    end
  end

  def sqd(routes, opts \\ []) do
    {:ok, handle} =
      Tron.new(:sqd,
        http_opts: [{:exchange, seam(routes)} | unmetered()],
        cache: Keyword.get(opts, :cache, false)
      )

    handle
  end

  def state(handle), do: elem(handle, 1)

  def calls(acc \\ []) do
    receive do
      {:called, tool, arguments, _reference} -> calls([{tool, arguments} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def drain do
    receive do
      _anything -> drain()
    after
      0 -> :ok
    end
  end

  def trongrid_height_routes do
    %{
      "getBlock" => "trongrid_block.sse",
      "solidityGetBlock" => "trongrid_solidity_block.sse"
    }
  end
end

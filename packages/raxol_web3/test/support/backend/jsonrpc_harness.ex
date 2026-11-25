defmodule Raxol.Web3.Backend.JSONRPCHarness do
  @moduledoc false
  # Fixtures and handle builders shared by the jsonrpc test files.

  alias Raxol.Web3.Backend.JSONRPC

  @fixtures Path.expand("../../fixtures/jsonrpc", __DIR__)

  # Every fixture below was recorded from https://rpc.mainnet.chain.robinhood.com
  # on 2026-09-14 and trimmed: blocks keep two transaction hashes, the log list
  # keeps two of four entries, and the contract's runtime code keeps its first
  # 32 bytes of 3,249, because the only question asked of it is whether there is
  # any. A fixture is not a mock. It is what the node actually said, and it is
  # what makes "the node's shape changed" a red test.
  def fixture(name),
    do: @fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()

  def result(name), do: fixture(name)["result"]

  # Both limiters are given room, as in `Raxol.Web3.Backend.BlockscoutTest`:
  # every test here shares one origin per URL, so the bucket and the breaker
  # would otherwise couple unrelated tests through it. They are
  # `Raxol.Web3.HTTPTest`'s subject.
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

  # Answers a JSON-RPC POST by method. A value may be a result, a one-argument
  # function of the params (for the methods whose answer depends on what was
  # asked, or on how many times it has been asked), or `{:error, code}` for a
  # node that refuses. A function may return either shape, because a node's
  # answer to one question changes: a block at the head is -32004 until it is
  # not.
  def serving(rpc) do
    fn _vetted, request, _opts ->
      %{"method" => method, "params" => params, "id" => id} = Jason.decode!(request.body)
      send(self(), {:rpc, method, params})

      answer =
        case Map.fetch(rpc, method) do
          {:ok, fun} when is_function(fun, 1) -> envelope(fun.(params))
          {:ok, answer} -> envelope(answer)
          :error -> %{"error" => %{"code" => -32_601}}
        end

      body = Map.merge(%{"jsonrpc" => "2.0", "id" => id}, answer)

      {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
    end
  end

  def envelope({:error, code}), do: %{"error" => %{"code" => code}}
  def envelope(result), do: %{"result" => result}

  def handle(rpc, opts \\ []) do
    http_opts = [{:exchange, serving(rpc)} | unmetered()]

    {:ok, handle} =
      JSONRPC.new(
        Keyword.get(opts, :chain_ref, "eip155:4663"),
        url: Keyword.get(opts, :url, "https://node.test/"),
        http_opts: http_opts,
        # Off by default, and not for convenience: the cache is per node and
        # keyed by origin, so two tests asking one URL the same question would
        # share an entry and the first to run would answer for the second. The
        # cache tests below give themselves their own URLs.
        cache: Keyword.get(opts, :cache, false),
        log_window: Keyword.get(opts, :log_window, 2_000),
        log_lookback: Keyword.get(opts, :log_lookback, 10_000)
      )

    handle
  end

  def state(handle), do: elem(handle, 1)

  def drain(acc \\ []) do
    receive do
      {:rpc, method, params} -> drain([{method, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def methods, do: Enum.map(drain(), &elem(&1, 0))

  # The node table, so a test can express "latest", "finalized" and the sample
  # block the average block time is derived from in one place.
  def blocks do
    fn
      ["latest", false] -> result("block")
      ["finalized", false] -> result("block_finalized")
      [number, false] -> Map.get(%{"0x3bd256c" => result("block_earlier")}, number)
    end
  end
end

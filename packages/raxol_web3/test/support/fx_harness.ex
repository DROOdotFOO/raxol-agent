defmodule Raxol.Web3.FXHarness do
  @moduledoc false
  # Recorded fixtures and exchange seams shared by the FX test files.

  alias Raxol.Web3.FX.{Chainlink, Sleuth}

  @sleuth_fixtures Path.expand("../fixtures/sleuth", __DIR__)
  @chainlink_fixtures Path.expand("../fixtures/chainlink", __DIR__)

  @key "test-key-not-real"
  @base_eur "0xc91d87e81fab8f93699ecf7ee9b44d11e1d53f0f"

  # The Sleuth API key every `sleuth/1` handle carries, so the redaction tests
  # refute the value that is actually in play.
  def key, do: @key

  # The EUR/USD proxy on Base, as `chainlink/1` serves it.
  def base_eur, do: @base_eur

  @feeds ~w(eur_usd_base eur_usd_ethereum chf_usd_ethereum sequencer_base)

  # Recorded 2026-09-30 from the live API and the live feeds. A fixture is what
  # the upstream said, so a changed shape is a red test here rather than a
  # production surprise.
  def sleuth_fixture(name), do: File.read!(Path.join(@sleuth_fixtures, "#{name}.json"))
  def feed(name), do: Jason.decode!(File.read!(Path.join(@chainlink_fixtures, "#{name}.json")))

  def limits do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _host, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  def sleuth(routes) do
    exchange = fn _vetted, request, _opts ->
      send(self(), {:request, request})
      [path | _] = String.split(request.path, "?")

      case Map.fetch(routes, path) do
        {:ok, {status, body}} -> {:ok, %{status: status, headers: [], body: body}}
        {:ok, body} -> {:ok, %{status: 200, headers: [], body: body}}
        :error -> {:ok, %{status: 404, headers: [], body: ~s({"error":"not found"})}}
      end
    end

    {:ok, sleuth} =
      Sleuth.new(api_key: @key, cache: false, http_opts: [{:exchange, exchange} | limits()])

    sleuth
  end

  # Answers `eth_call` from the recorded feeds, keyed by (chain, proxy,
  # selector). `overrides` replaces a recorded result, by the same key. The
  # chain is read off the URL path: `/base` is Base, `/eth` Ethereum, and any
  # other path a chain where none of the proxies is deployed, which answers
  # `"0x"` as a node does for a call to an address with no code.
  def chainlink(opts \\ []) do
    overrides = Keyword.get(opts, :overrides, %{})

    table =
      for name <- @feeds, rec = feed(name), {selector, field} <- selectors(), into: %{} do
        {{rec["chain_id"], String.downcase(rec["proxy"]), selector}, rec[field]}
      end
      |> Map.merge(overrides)

    exchange = fn _vetted, request, _opts ->
      # A gateway that picks the network by header, ahead of the path: the
      # first `x-net`, its name compared case-insensitively.
      net = Enum.find_value(request.headers, &x_net/1)

      chain =
        cond do
          net == "impostor" -> :impostor
          request.path =~ "base" -> 8453
          request.path =~ "eth" -> 1
          # A chain answering only what `overrides` puts under `:impostor`.
          request.path =~ "impostor" -> :impostor
          true -> :elsewhere
        end

      %{"id" => id, "params" => [%{"to" => to, "data" => data}, _tag]} =
        Jason.decode!(request.body)

      send(self(), {:eth_call, request.path, String.downcase(to), data})
      result = Map.get(table, {chain, String.downcase(to), data}, "0x")

      {:ok,
       %{status: 200, headers: [], body: Jason.encode!(%{jsonrpc: "2.0", id: id, result: result})}}
    end

    Chainlink.new(
      rpc_urls:
        Keyword.get(opts, :rpc_urls, %{
          1 => "https://rpc.test/eth",
          8453 => "https://rpc.test/base"
        }),
      http_opts: [{:exchange, exchange}, {:headers, Keyword.get(opts, :headers, [])} | limits()],
      now: fn -> Keyword.get(opts, :now, recorded_at()) end,
      cache: Keyword.get(opts, :cache, false)
    )
  end

  defp x_net({name, value}) do
    if String.downcase(name) == "x-net", do: value
  end

  defp selectors,
    do: [
      {"0x7284e416", "description"},
      {"0x313ce567", "decimals"},
      {"0xfeaf968c", "latestRoundData"}
    ]

  def updated_at(name) do
    {:ok, %{updated_at: at}} = Chainlink.decode_round(feed(name)["latestRoundData"])
    at
  end

  # The moment the fixtures were read: every feed was fresh then.
  def recorded_at do
    feed("eur_usd_base")["read_at"]
    |> DateTime.from_iso8601()
    |> elem(1)
    |> DateTime.to_unix()
  end

  defp word(n), do: <<n::signed-256>>

  def round_hex(answer, started_at, updated_at) do
    "0x" <>
      Base.encode16(word(1) <> word(answer) <> word(started_at) <> word(updated_at) <> word(1),
        case: :lower
      )
  end

  def asset(fields) do
    Map.merge(
      %{peg_currency: "EUR", yield_bearing?: false, price_usd: Decimal.new("1.1350")},
      Map.new(fields)
    )
  end

  def rates, do: %{"EUR" => {:ok, %{rate: Decimal.new("1.1350"), precision_bps: 10}}}
end

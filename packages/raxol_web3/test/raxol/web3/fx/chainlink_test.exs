defmodule Raxol.Web3.FX.ChainlinkTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.FXHarness

  alias Raxol.Web3.FX.Chainlink

  @base_eur Raxol.Web3.FXHarness.base_eur()
  @eth_eur "0xb49f677943bc038e9857d61e7d053caa2c1734c1"
  @base_seq "0xbcf85224fc0756b9fa45aa7892530b47e10b6433"

  describe "Chainlink" do
    test "EUR comes from the Base feed first, with its precision" do
      assert {:ok, rate} = Chainlink.rate(chainlink(), "EUR")

      assert rate.source == {8453, "0xc91D87E81faB8f93699ECf7Ee9B44D11e1D53F0F"}
      assert rate.precision_bps == 10
      assert Decimal.gt?(rate.rate, "1.0") and Decimal.lt?(rate.rate, "1.3")
    end

    test "CHF comes from Ethereum, USD is the identity, anything else has no feed" do
      assert {:ok, %{source: {1, _}, precision_bps: 15}} = Chainlink.rate(chainlink(), "CHF")
      assert {:ok, %{rate: one, source: :identity}} = Chainlink.rate(chainlink(), "USD")
      assert Decimal.equal?(one, 1)
      assert {:error, :no_feed} = Chainlink.rate(chainlink(), "GBP")
    end

    test "a stale primary fails over; the fallback's own heartbeat still applies" do
      # Past Base's 3960 s budget, well inside Ethereum's 95040 s.
      now = updated_at("eur_usd_base") + 3_961
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(now: now), "EUR")

      # Past both, so no rate at all, reported by the primary.
      now = updated_at("eur_usd_ethereum") + 95_041
      assert {:error, :stale} = Chainlink.rate(chainlink(now: now), "EUR")
    end

    test "the freshness margin is exactly heartbeat * 1.1" do
      at = updated_at("chf_usd_ethereum")
      assert {:ok, _} = Chainlink.rate(chainlink(now: at + 95_040), "CHF")
      assert {:error, :stale} = Chainlink.rate(chainlink(now: at + 95_041), "CHF")
    end

    test "a down or freshly restarted Base sequencer skips the Base feed" do
      now = recorded_at()

      down = %{{8453, @base_seq, "0xfeaf968c"} => round_hex(1, now - 7_200, now)}
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(overrides: down), "EUR")

      restarted = %{{8453, @base_seq, "0xfeaf968c"} => round_hex(0, now - 60, now)}
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(overrides: restarted), "EUR")
    end

    test "the sequencer grace period is exactly an hour" do
      now = recorded_at()

      up_an_hour = %{{8453, @base_seq, "0xfeaf968c"} => round_hex(0, now - 3_600, now)}
      assert {:ok, %{source: {8453, _}}} = Chainlink.rate(chainlink(overrides: up_an_hour), "EUR")

      a_second_short = %{{8453, @base_seq, "0xfeaf968c"} => round_hex(0, now - 3_599, now)}

      assert {:ok, %{source: {1, _}}} =
               Chainlink.rate(chainlink(overrides: a_second_short), "EUR")
    end

    test "a lagging node's latest round is judged by its own updatedAt" do
      # The node answers `latest` from a head an hour and a bit behind: the
      # clock is fresh, the round is not.
      now = recorded_at()
      lagging = %{{8453, @base_eur, "0xfeaf968c"} => round_hex(113_000_000, now, now - 3_961)}

      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(overrides: lagging), "EUR")
    end

    test "a proxy that is not the expected pair is blocked, not failed over" do
      wrong = %{{8453, @base_eur, "0x7284e416"} => feed("chf_usd_ethereum")["description"]}

      assert {:error, {:blocked, :feed_mismatch}} =
               Chainlink.rate(chainlink(overrides: wrong), "EUR")
    end

    test "an empty answer is a failed read that fails over, not a mismatch" do
      # The Base URL reaches a chain where the proxy has no code.
      misrouted = %{8453 => "https://rpc.test/elsewhere", 1 => "https://rpc.test/eth"}
      assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(rpc_urls: misrouted), "EUR")

      only = %{8453 => "https://rpc.test/elsewhere"}
      assert {:error, {:decode_failed, _}} = Chainlink.rate(chainlink(rpc_urls: only), "EUR")
    end

    test "a zero or negative answer is not a rate, and the primary's fails over" do
      now = recorded_at()
      eth_only = %{1 => "https://rpc.test/eth"}

      for answer <- [0, -1, -113_000_000] do
        bad = %{{1, @eth_eur, "0xfeaf968c"} => round_hex(answer, now, now)}

        assert {:error, :bad_answer} =
                 Chainlink.rate(chainlink(overrides: bad, rpc_urls: eth_only), "EUR")

        bad_primary = %{{8453, @base_eur, "0xfeaf968c"} => round_hex(answer, now, now)}
        assert {:ok, %{source: {1, _}}} = Chainlink.rate(chainlink(overrides: bad_primary), "EUR")
      end
    end

    test "a chain with no configured RPC URL is skipped" do
      assert {:ok, %{source: {1, _}}} =
               Chainlink.rate(chainlink(rpc_urls: %{1 => "https://rpc.test/eth"}), "EUR")

      assert {:error, :no_rpc} = Chainlink.rate(chainlink(rpc_urls: %{}), "EUR")
    end
  end

  describe "Chainlink, with the identity cache on" do
    # The cache is node-wide, so each test gets a host nobody else uses.
    defp urls(base_path) do
      host = "rpc-#{System.unique_integer([:positive])}.test"
      {%{8453 => "https://#{host}#{base_path}", 1 => "https://#{host}/eth"}, host}
    end

    test "a wrong answer on one handle neither blocks nor pins another on the same host" do
      {misrouted, host} = urls("/elsewhere")
      healthy = %{8453 => "https://#{host}/base", 1 => "https://#{host}/eth"}

      assert {:ok, %{source: {1, _}}} =
               Chainlink.rate(chainlink(cache: true, rpc_urls: misrouted), "EUR")

      assert {:ok, %{source: {8453, _}}} =
               Chainlink.rate(chainlink(cache: true, rpc_urls: healthy), "EUR")

      # And the healthy handle's cached identity is not the misrouted one's:
      # it reads its own, which is still the empty answer, and fails over.
      assert {:ok, %{source: {1, _}}} =
               Chainlink.rate(chainlink(cache: true, rpc_urls: misrouted), "EUR")
    end

    test "a sibling's cached identity does not vouch for a handle on another path" do
      # `/impostor` reaches a contract at the Base EUR proxy address that
      # answers as CHF/USD, with a live sequencer and a decodable round at 2.00.
      now = recorded_at()
      base = feed("eur_usd_base")

      impostor = %{
        {:impostor, @base_eur, "0x7284e416"} => feed("chf_usd_ethereum")["description"],
        {:impostor, @base_eur, "0x313ce567"} => base["decimals"],
        {:impostor, @base_eur, "0xfeaf968c"} => round_hex(200_000_000, now, now),
        {:impostor, @base_seq, "0xfeaf968c"} => round_hex(0, now - 7_200, now)
      }

      {misrouted, host} = urls("/impostor")
      healthy = %{8453 => "https://#{host}/base", 1 => "https://#{host}/eth"}
      misrouted = Map.delete(misrouted, 1)

      blocked = {:error, {:blocked, :feed_mismatch}}
      read = &Chainlink.rate(chainlink(cache: true, overrides: impostor, rpc_urls: &1), "EUR")

      assert read.(misrouted) == blocked
      assert {:ok, %{source: {8453, _}}} = read.(healthy)
      assert read.(misrouted) == blocked
    end

    test "nor for a handle on the same URL routed elsewhere by a header" do
      now = recorded_at()
      base = feed("eur_usd_base")

      impostor = %{
        {:impostor, @base_eur, "0x7284e416"} => feed("chf_usd_ethereum")["description"],
        {:impostor, @base_eur, "0x313ce567"} => base["decimals"],
        {:impostor, @base_eur, "0xfeaf968c"} => round_hex(200_000_000, now, now),
        {:impostor, @base_seq, "0xfeaf968c"} => round_hex(0, now - 7_200, now)
      }

      {rpc_urls, _host} = urls("/base")
      rpc_urls = Map.delete(rpc_urls, 1)

      read = fn headers ->
        Chainlink.rate(
          chainlink(cache: true, overrides: impostor, rpc_urls: rpc_urls, headers: headers),
          "EUR"
        )
      end

      routed = [{"x-net", "impostor"}]
      assert read.(routed) == {:error, {:blocked, :feed_mismatch}}
      assert {:ok, %{source: {8453, _}}} = read.([])
      assert read.(routed) == {:error, {:blocked, :feed_mismatch}}

      # A gateway honouring the first of two `x-net` headers routes these two
      # handles apart; their identities must not be shared either.
      {rpc_urls, _host} = urls("/base")
      rpc_urls = Map.delete(rpc_urls, 1)

      read2 = fn headers ->
        Chainlink.rate(
          chainlink(cache: true, overrides: impostor, rpc_urls: rpc_urls, headers: headers),
          "EUR"
        )
      end

      first_impostor = [{"x-net", "impostor"}, {"x-net", "base"}]
      assert read2.(first_impostor) == {:error, {:blocked, :feed_mismatch}}
      assert {:ok, _} = read2.([{"x-net", "base"}, {"x-net", "impostor"}])
      assert read2.(first_impostor) == {:error, {:blocked, :feed_mismatch}}

      # The same, with the names in different case: a gateway compares them
      # case-insensitively, so the cache key must too.
      {rpc_urls, _host} = urls("/base")
      rpc_urls = Map.delete(rpc_urls, 1)

      read3 = fn headers ->
        Chainlink.rate(
          chainlink(cache: true, overrides: impostor, rpc_urls: rpc_urls, headers: headers),
          "EUR"
        )
      end

      first_impostor = [{"X-Net", "impostor"}, {"x-net", "base"}]
      assert read3.(first_impostor) == {:error, {:blocked, :feed_mismatch}}
      assert {:ok, _} = read3.([{"x-net", "base"}, {"X-Net", "impostor"}])
      assert read3.(first_impostor) == {:error, {:blocked, :feed_mismatch}}
    end

    test "route_id separates header orders a gateway would route apart" do
      route = &Chainlink.route_id(chainlink(headers: &1))

      # Map headers are what `Raxol.Web3.HTTP` accepts too; same route as the list.
      assert route.(%{"x-net" => "base"}) == route.([{"x-net", "base"}])

      refute route.([{"x-net", "base"}, {"X-Net", "impostor"}]) ==
               route.([{"X-Net", "impostor"}, {"x-net", "base"}])

      # Order across different names is not a route.
      assert route.([{"x-net", "base"}, {"x-key", "k"}]) ==
               route.([{"x-key", "k"}, {"x-net", "base"}])
    end

    test "a matching identity is read once; the round is read every time" do
      {rpc_urls, _host} = urls("/base")
      fx = chainlink(cache: true, rpc_urls: rpc_urls)

      assert {:ok, %{source: {8453, _}}} = Chainlink.rate(fx, "EUR")
      assert_received {:eth_call, "/base", @base_eur, "0x7284e416"}
      assert_received {:eth_call, "/base", @base_eur, "0x313ce567"}
      assert_received {:eth_call, "/base", @base_eur, "0xfeaf968c"}

      assert {:ok, %{source: {8453, _}}} = Chainlink.rate(fx, "EUR")
      refute_received {:eth_call, "/base", @base_eur, "0x7284e416"}
      refute_received {:eth_call, "/base", @base_eur, "0x313ce567"}
      assert_received {:eth_call, "/base", @base_eur, "0xfeaf968c"}
    end
  end
end

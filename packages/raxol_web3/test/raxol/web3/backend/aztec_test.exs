defmodule Raxol.Web3.Backend.AztecTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.AztecHarness

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Aztec
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Router

  @chain "aztec:mainnet"

  # A deployed mainnet instance, a mined transaction, and a transaction that
  # was in the pool when the fixtures were recorded. All three are from the
  # recorded responses, so the assertions below and the live tests at the end
  # ask about the same objects.
  @instance {:aztec, "0x1df9626e34c9e837d8f1402207693948f3869c3e8b920939c19697c24af18d07"}
  @mined "0x0a13cfae47782debfb1e7dbe15e7e033fc65a3eb0edf2377b32ea533a6c912f1"

  describe "sources" do
    test "the temporary path is carried as data, with its network and its dated status" do
      assert {url, "MAINNET", :temporary_path} = Aztec.sources()[@chain]

      # The operational fact this backend exists around: the segment standing
      # where a key would stand says out loud that it is temporary.
      assert url == "https://api.aztecscan.xyz/v1/temporary-api-key"
    end

    test "the self-hosted fallback is the same module with another base url" do
      assert {:ok, {Aztec, %{source: :chicmoz, base_url: base_url}} = fallback} =
               Aztec.new(@chain, base_url: "https://chicmoz.example.org/v1/local/")

      assert base_url == "https://chicmoz.example.org/v1/local"

      # Two names for one module: `backend/0` is the chain that config and a
      # router's failover order are written against, and `backend/1` is the
      # source `Router.coverage/2` reports.
      assert Aztec.backend() == :aztec
      assert Backend.name(fallback) == :chicmoz

      {:ok, hosted} = Aztec.new(@chain)
      assert Backend.name(hosted) == :aztecscan

      # The name is the credential a handle presents rather than the option it
      # was built from, so configuring the hosted URL by hand is still the
      # temporary path.
      hosted_url = "https://api.aztecscan.xyz/v1/temporary-api-key"
      {:ok, configured} = Aztec.new(@chain, base_url: hosted_url)
      assert Backend.name(configured) == :aztecscan
      refute inspect(configured) =~ "temporary-api-key"
    end

    test "a base url that cannot be dialled is refused at construction, not per read" do
      assert {:error, {:invalid_base_url, :scheme}} =
               Aztec.new(@chain, base_url: "http://chicmoz.example.org/v1/local")

      assert {:error, {:invalid_base_url, :host}} =
               Aztec.new(@chain, base_url: "https:///v1/local")
    end

    test "the rate limit is seeded and labelled, and a caller can still override it" do
      assert Aztec.rate_limit() == [capacity: 5, refill_per_second: 1.0]

      assert {:ok, {Aztec, %{http_opts: seeded}}} = Aztec.new(@chain)
      assert seeded[:rate_limit] == [capacity: 5, refill_per_second: 1.0]

      own = [capacity: 2, refill_per_second: 0.5]
      assert {:ok, {Aztec, %{http_opts: given}}} = Aztec.new(@chain, http_opts: [rate_limit: own])
      assert given[:rate_limit] == own
    end
  end

  describe "capabilities" do
    test "the declared set is exactly what the surface answers" do
      # Asserted rather than described, so a callback added or dropped without
      # a probe behind it is a red test here instead of a surprise at a router.
      assert Aztec.capabilities(state(handle(%{}))) == [
               :get_transaction,
               :get_block,
               :contract_metadata
             ]
    end

    test "token_balances is absent, and nothing stands in for it" do
      # The central point of issue #1030. A private note is unobservable by
      # construction, so an empty page would be a lie a caller cannot tell
      # apart from an account holding nothing.
      handle = handle(%{})

      refute Backend.supports?(handle, :token_balances)

      # Any arity. The callback is `token_balances/3` since the cursor
      # amendment, so a check pinned to the old arity would pass on a module
      # that had grown the new one.
      refute Enum.any?(Aztec.__info__(:functions), &match?({:token_balances, _arity}, &1))

      assert {:error, {:unsupported, :token_balances}} =
               Backend.call(handle, :token_balances, [@instance, []])

      # And through a router whose only source for this chain is this one.
      assert {:error, {:unsupported, :token_balances}} =
               Router.call(Router.new([handle]), @chain, :token_balances, [@instance, []])

      # Refused before anything left the process, so there is no empty page
      # anywhere in the path either.
      assert [] == drain()
    end

    test "the account-shaped and private-shaped reads are all absent" do
      handle = handle(%{})

      for callback <- [
            :account_info,
            :list_transactions,
            :list_token_transfers,
            :get_logs,
            :list_nfts,
            :read_contract,
            :resolve_name,
            :raw_request
          ] do
        refute Backend.supports?(handle, callback), "#{callback} is declared"

        assert match?({:error, {:unsupported, ^callback}}, Backend.call(handle, callback, [nil])),
               "#{callback} answered something"
      end
    end

    test "coverage for this chain is smaller than an EVM chain's, which is the point" do
      # ADR-0039 decision 3: absence is the answer, and coverage/2 is what
      # makes the smaller surface legible to an operator instead of arriving as
      # an error per call. Polygon is the comparison because no test in this
      # suite records a failure against that host.
      {:ok, evm} = Blockscout.new("eip155:137")
      router = Router.new([handle(%{}), evm])

      aztec = Router.coverage(router, @chain)
      blockscout = Router.coverage(router, "eip155:137")

      assert map_size(aztec) < map_size(blockscout)
      assert aztec[:chain_info] == [:aztecscan]
      assert aztec[:block_height] == [:aztecscan]
      assert aztec[:get_transaction] == [:aztecscan]
      refute Map.has_key?(aztec, :token_balances)
      refute Map.has_key?(aztec, :list_transactions)
      # Named by its module, because one Blockscout handle is one host and
      # that backend declines `backend/1`.
      assert blockscout[:token_balances] == [:blockscout]
      assert blockscout[:list_transactions] == [:blockscout]
    end
  end

  describe "chain_info/1" do
    test "carries the two counters that exist and nils the two that do not" do
      handle =
        handle(%{
          "/l2/info" => fixture("info.json"),
          "/l2/stats/average-block-time" => fixture("average_block_time.json"),
          "/l2/stats/total-tx-effects" => fixture("total_tx_effects.json")
        })

      assert {:ok, info} = Backend.call(handle, :chain_info)

      assert info.chain_ref == @chain
      # Upstream sends this as a JSON string, so the value asserts the parse
      # as much as the reading.
      assert info.average_block_time_ms == 63_555
      assert info.total_transactions == 36_869
      # A height exists on this chain and a count of blocks does not. Reading
      # the former as the latter is the mistake ADR-0038 records.
      assert info.total_blocks == nil
      # No account resource, so no count of accounts.
      assert info.total_addresses == nil
    end

    test "a number that only partly parses fails the read instead of being truncated" do
      # `Integer.parse/1` answers `{1, ".5e18"}`, `{1, "e18"}`, `{0, "x1f"}`
      # and `{12, "abc"}` for the first four, so accepting `{number, _rest}`
      # handed a caller 1, 1, 0 and 12 as an average block time. A wrong
      # number is worse than no number: nothing downstream can tell it apart
      # from a real one.
      for probe <- ["1.5e18", "1e18", "0x1f", "12abc", true] do
        handle =
          handle(%{
            "/l2/info" => fixture("info.json"),
            "/l2/stats/average-block-time" => Jason.encode!(probe),
            "/l2/stats/total-tx-effects" => fixture("total_tx_effects.json")
          })

        assert {:error, {:decode_failed, :average_block_time_ms}} =
                 Backend.call(handle, :chain_info),
               "#{inspect(probe)} was accepted"
      end
    end

    test "a source pointed at another network is refused before its counters are read" do
      handle = handle(%{"/l2/info" => ~s({"l2NetworkId":"TESTNET","l1ChainId":11155111})})

      assert {:error, {:decode_failed, :network_mismatch}} = Backend.call(handle, :chain_info)

      # The failure mode a configured fallback actually has is a URL aimed at
      # the wrong network, and it is the only one that answers confidently.
      assert endpoints() == ["/l2/info"]
    end
  end

  describe "block_height/1" do
    test "the height and its finalized half come out of one response" do
      handle = handle(%{"/l2/tips" => fixture("tips.json")})

      assert {:ok, height} = Backend.call(handle, :block_height)

      assert height.unit == :block
      assert height.height == 83_597
      assert height.finalized_height == 83_561
      assert height.finalized_height < height.height

      # One request, which is the whole reason `l2/tips` is used instead of
      # composing a height with a separately fetched finality.
      assert endpoints() == ["/l2/tips"]
    end

    test "the indexer reports the measure this source publishes and omits the two it does not" do
      handle = handle(%{"/l2/tips" => fixture("tips.json")})

      assert {:ok, %{indexer: indexer}} = Backend.call(handle, :block_height)

      assert indexer.finished? == true
      assert indexer.lag_seconds == 24
      refute Map.has_key?(indexer, :indexed_ratio)
      refute Map.has_key?(indexer, :lag_blocks)
    end

    test "an unreadable staleness costs the lag, never the height" do
      # `stalenessMs` is diagnostic and `block_height/1` is a required
      # callback, so an upstream shipping one bad optional field must not take
      # the height down with it -- `{:decode_failed, _}` fails the router over,
      # and every source publishes the same field.
      for probe <- [~s("1.5e18"), ~s("12abc"), "true", "null"] do
        body = ~s({"tips":{"proposed":{"number":7}},"stalenessMs":#{probe}})

        assert {:ok, height} = Backend.call(handle(%{"/l2/tips" => body}), :block_height),
               "#{probe} failed the read"

        assert height.height == 7

        # No age, rather than a truncated one. Same answer a negative age gets.
        refute Map.has_key?(height.indexer, :lag_seconds)
      end
    end

    test "a ladder whose finalized rung is above the head is refused, not repaired" do
      # The one invariant the height shape exists to express. A consumer
      # computing confirmation depth from an inverted pair reads a negative
      # number, so the read fails and the router tries the other source.
      body = ~s({"tips":{"proposed":{"number":100},"finalized":{"block":{"number":101}}}})

      assert {:error, {:decode_failed, :tips}} =
               Backend.call(handle(%{"/l2/tips" => body}), :block_height)
    end

    test "a chain with no finalized rung yet reports nil rather than zero" do
      body = ~s({"tips":{"proposed":{"number":3}},"stale":true,"stalenessMs":90000})

      assert {:ok, height} = Backend.call(handle(%{"/l2/tips" => body}), :block_height)

      assert height.height == 3
      assert height.finalized_height == nil
      assert height.indexer == %{finished?: false, lag_seconds: 90}
    end

    test "a body that is not the tips shape at all is a decode failure, not a crash" do
      assert {:error, {:decode_failed, :tips}} =
               Backend.call(handle(%{"/l2/tips" => ~s({"error":"nope"})}), :block_height)

      assert {:error, {:decode_failed, :not_an_object}} =
               Backend.call(handle(%{"/l2/tips" => "83597"}), :block_height)
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle =
        handle(%{"/l2/tips" => fixture("tips.json")}, cache: true, base_url: own_origin())

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert endpoints() == ["/l2/tips", "/l2/tips"]
    end
  end

  describe "beyond the contract" do
    test "rollup/1 is where the two facts that identify an L2 are visible" do
      # `chain_info()` has no field for an L1 chain id or a rollup version,
      # and widening a shape shared by every chain for one chain's identity is
      # what ADR-0033 section 7 refuses.
      handle = handle(%{"/l2/info" => fixture("info.json")})

      assert {:ok, rollup} = Aztec.rollup(state(handle))

      assert rollup.network == "MAINNET"
      assert rollup.l1_chain_id == 1
      assert rollup.rollup_version == "4248422647"
      assert rollup.l1_rollup == {:evm, "0x91ff8bbd8ebb07893010d50a48a1609e5ebd8e34"}
      assert rollup.l1_registry == {:evm, "0x35b22e09ee0390539439e24f06da43d83f90e298"}

      # Normalized down to the two anchors that identify the rollup, rather
      # than the upstream's eleven-address map passed through.
      refute Map.has_key?(rollup, :l1ContractAddresses)
    end

    test "tips/1 carries the whole ladder, which is what finalized_height cannot" do
      handle = handle(%{"/l2/tips" => fixture("tips.json")})

      assert {:ok, tips} = Aztec.tips(state(handle))

      assert tips.proposed == 83_597
      assert tips.checkpointed == 83_597
      assert tips.proven == 83_589
      assert tips.finalized == 83_561
      assert tips.stale? == false
      assert tips.staleness_ms == 24_815
      assert tips.degraded? == false
    end
  end

  describe "the response cache" do
    test "a repeated read is served from the cache, and the upstream is asked once" do
      routes = %{
        "/l2/info" => fixture("info.json"),
        "/l2/stats/average-block-time" => fixture("average_block_time.json"),
        "/l2/stats/total-tx-effects" => fixture("total_tx_effects.json")
      }

      handle = handle(routes, cache: true, base_url: own_origin())

      assert {:ok, first} = Backend.call(handle, :chain_info)
      assert {:ok, second} = Backend.call(handle, :chain_info)

      assert first == second
      assert length(endpoints()) == 3
    end

    test "a non-2xx is not cached, so a withdrawn prefix cannot outlive the breaker" do
      handle =
        handle(%{"/l2/tips" => {403, "<html>challenge</html>"}},
          cache: true,
          base_url: own_origin()
        )

      assert {:error, {:http, 403}} = Backend.call(handle, :block_height)
      assert {:error, {:http, 403}} = Backend.call(handle, :block_height)

      assert length(endpoints()) == 2
    end

    test "two key prefixes on one host do not share a cache entry" do
      # The credential is a path segment on this upstream, and
      # `Raxol.Web3.HTTP` keys on `{origin_id, fragment}` where an origin id is
      # only `scheme://host:port`. A fragment that was the endpoint path alone
      # named the prefix in neither half, so a second or rotated key on the same
      # host was served the first key's body.
      host = "https://chicmoz-#{System.unique_integer([:positive])}.example.org"
      endpoint = "/l2/tx-effects/#{@mined}"

      first =
        handle(%{endpoint => fixture("tx_effects.json")},
          cache: true,
          base_url: host <> "/v1/key-one"
        )

      second =
        handle(%{endpoint => patched("tx_effects.json", %{"blockHeight" => 90_001})},
          cache: true,
          base_url: host <> "/v1/key-two"
        )

      assert {:ok, %{block: 83_582}} = Backend.call(first, :get_transaction, [@mined])
      assert {:ok, %{block: 90_001}} = Backend.call(second, :get_transaction, [@mined])

      assert length(endpoints()) == 2
    end
  end
end

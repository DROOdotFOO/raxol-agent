defmodule Raxol.Web3.Backend.AztecReadsTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.AztecHarness

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Aztec
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @chain "aztec:mainnet"

  # A deployed mainnet instance, a mined transaction, and a transaction that
  # was in the pool when the fixtures were recorded. All three are from the
  # recorded responses, so the assertions below and the live tests at the end
  # ask about the same objects.
  @instance {:aztec, "0x1df9626e34c9e837d8f1402207693948f3869c3e8b920939c19697c24af18d07"}
  @mined "0x0a13cfae47782debfb1e7dbe15e7e033fc65a3eb0edf2377b32ea533a6c912f1"
  @pooled "0x0b80d11d7315a41d662199175a6dfa14a0ffa92fc01b8bd1abb0d34ae5633803"

  describe "get_transaction/2" do
    test "a mined transaction comes from the effect record, with no counterparties" do
      handle = handle(%{"/l2/tx-effects/#{@mined}" => fixture("tx_effects.json")})

      assert {:ok, tx} = Backend.call(handle, :get_transaction, [@mined])

      assert tx.hash == @mined
      assert tx.status == :success
      assert tx.block == 83_582
      assert tx.fee == 6_466_668_918_033_303_460
      assert DateTime.to_unix(tx.timestamp, :millisecond) == 1_789_380_527_000

      # The chain, not the source. The record carries `feePayer` and
      # `initiator`, and neither is a sender: promoting either would produce a
      # field a caller cannot tell apart from a measured one.
      assert tx.from == nil
      assert tx.to == nil
      assert tx.value == nil
      assert tx.method == nil
    end

    test "a transaction still in the pool is pending, which is read rather than assumed" do
      handle = handle(%{"/l2/txs/#{@pooled}" => fixture("tx_pending.json")})

      assert {:ok, tx} = Backend.call(handle, :get_transaction, [@pooled])

      assert tx.status == :pending
      assert tx.block == nil
      # Gas limits and max fees are bounds, not a fee. What was paid is known
      # once it is mined.
      assert tx.fee == nil
      assert DateTime.to_unix(tx.timestamp, :millisecond) == 1_788_027_417_612

      # The effect first, the pool second: `l2/txs` is the pending pool and
      # answers 404 for a hash that has been mined.
      assert endpoints() == ["/l2/tx-effects/#{@pooled}", "/l2/txs/#{@pooled}"]
    end

    test "a hash that is neither mined nor pooled is not found" do
      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle(%{}), :get_transaction, [@mined])
    end

    test "a nonzero revert code is reverted, and an unreadable one is refused" do
      reverted = patched("tx_effects.json", %{"revertCode" => %{"code" => 1}})

      assert {:ok, %{status: :reverted}} =
               Backend.call(
                 handle(%{"/l2/tx-effects/#{@mined}" => reverted}),
                 :get_transaction,
                 [@mined]
               )

      # A mined effect whose revert code cannot be read is not a transaction of
      # unknown status, because the contract has no such status.
      unreadable = patched("tx_effects.json", %{"revertCode" => nil})

      assert {:error, {:decode_failed, :revert_code}} =
               Backend.call(
                 handle(%{"/l2/tx-effects/#{@mined}" => unreadable}),
                 :get_transaction,
                 [@mined]
               )
    end

    test "a revert code that only partly parses is refused, never read as success" do
      # The one field where a truncating parse changes an ANSWER rather than a
      # statistic: `{0, "x1f"}` for "0x1f" reads a reverted transaction as
      # successful, and a caller settling on that has no way to tell.
      for probe <- ["0x1f", "1.5e18", "1e18", "12abc", true] do
        body = patched("tx_effects.json", %{"revertCode" => %{"code" => probe}})

        assert {:error, {:decode_failed, :revert_code}} =
                 Backend.call(
                   handle(%{"/l2/tx-effects/#{@mined}" => body}),
                   :get_transaction,
                   [@mined]
                 ),
               "#{inspect(probe)} was accepted"
      end
    end

    test "a hash cannot reshape the path it is interpolated into" do
      assert {:error, {:invalid_argument, "hash"}} =
               Backend.call(handle(%{}), :get_transaction, ["l2/info?x=1"])

      # Refused before a request exists: a separator is outside the allowlist.
      assert endpoints() == []
    end
  end

  describe "get_block/2" do
    test "a block maps to the contract's shape, and the coinbase is an L1 address" do
      handle = handle(%{"/l2/blocks/83582" => fixture("block.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [83_582])

      assert block.height == 83_582
      assert block.hash == "0x104fcc7b43c69f0f63b465740b8d0b412b57a46e899caed25727b3de3e745027"
      assert block.transactions_count == 1
      assert DateTime.to_unix(block.timestamp, :millisecond) == 1_789_380_527_000

      # 20 bytes, paid on L1, so the EVM tag is the accurate one even inside an
      # Aztec block.
      assert block.miner == {:evm, "0x06a8eecfba446ca78704fd1ed002cb13cec12bff"}
    end

    test "the head can be asked for by name, because the upstream takes a height or a tag" do
      handle = handle(%{"/l2/blocks/latest" => fixture("block.json")})

      assert {:ok, %{height: 83_582}} = Backend.call(handle, :get_block, ["latest"])
    end

    test "a block whose height cannot be read is a decode failure" do
      handle = handle(%{"/l2/blocks/1" => ~s({"hash":"0xabc"})})

      assert {:error, {:decode_failed, :block}} = Backend.call(handle, :get_block, [1])
    end
  end

  describe "contract_metadata/2" do
    test "an instance answers the shape, and verified? is measured rather than defaulted" do
      {:aztec, address} = @instance
      handle = handle(%{"/l2/contract-instances/#{address}" => fixture("contract_instance.json")})

      assert {:ok, metadata} = Backend.call(handle, :contract_metadata, [@instance])

      # Verification is a real concept here: chicmoz serves verify-source and a
      # verifiedSourceOnly filter, and that filter answered `[]` on 2026-09-14
      # while all 23 mainnet instances carried a null sourceCodeUrl. So false
      # means no source is registered, not that a verification failed.
      assert metadata.verified? == false
      assert metadata.name == nil
      # `selectorMap` carries no argument types, so it is not an ABI, and no
      # mainnet instance has an artifact to record a mapping against.
      assert metadata.abi == nil
      assert metadata.language == nil
      assert metadata.compiler_version == nil
      assert metadata.proxy_type == nil
    end

    test "a registered source url and artifact name are what fill the two fields that exist" do
      # The fields are present and null in every recorded mainnet instance, so
      # this row sets them to prove the mapping rather than the default.
      {:aztec, address} = @instance

      body =
        patched("contract_instance.json", %{
          "sourceCodeUrl" => "https://example.org/src",
          "artifactContractName" => "TokenContract"
        })

      handle = handle(%{"/l2/contract-instances/#{address}" => body})

      assert {:ok, %{verified?: true, name: "TokenContract"}} =
               Backend.call(handle, :contract_metadata, [@instance])
    end

    test "an address with no deployed instance is not found rather than an empty record" do
      handle = handle(%{})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :contract_metadata, [@instance])
    end
  end

  describe "the temporary path's revocation" do
    # Each of these owns its origins. The breaker table is per node and keyed
    # by origin, so a test that asserts on breaker state has to be the only
    # writer of the key it reads, and a shared host would make that a race with
    # an async sibling.
    defp pair(primary_answer, opts \\ []) do
      suffix = System.unique_integer([:positive])
      primary_url = "https://revoked-#{suffix}.example.org/v1/temporary-api-key"
      fallback_url = "https://chicmoz-#{suffix}.example.org/v1/local"

      exchange = fn vetted, request, _opts ->
        send(self(), {:request, vetted.hostname, endpoint(request.path)})

        if String.starts_with?(vetted.hostname, "revoked-") do
          primary_answer
        else
          {:ok, %{status: 200, headers: [], body: fixture("tips.json")}}
        end
      end

      http_opts = [{:exchange, exchange} | Keyword.merge(unmetered(), opts)]

      {:ok, primary} =
        Aztec.new(@chain, base_url: primary_url, http_opts: http_opts, cache: false)

      {:ok, fallback} =
        Aztec.new(@chain, base_url: fallback_url, http_opts: http_opts, cache: false)

      {primary, fallback, {:origin, Origin.id(URI.new!(primary_url))}}
    end

    defp withdrawn do
      # The measured shape, 2026-09-14: substituting a bogus key segment
      # answers 404 text/plain from the edge, not 403.
      {:ok, %{status: 404, headers: [], body: fixture("revoked_prefix_404.txt")}}
    end

    defp challenged do
      # The other shape a key-gated edge answers, and the one Blockscout's
      # chain 4663 row measured on 2026-09-13. The body is irrelevant: a
      # non-2xx carries none onward.
      {:ok, %{status: 403, headers: [], body: "<html>challenge</html>"}}
    end

    test "a withdrawn prefix 404s an endpoint that has no resource to miss" do
      {primary, _fallback, _key} = pair(withdrawn())

      # `/l2/tips` takes no parameter, so a 404 on it cannot mean the resource
      # is absent. Every endpoint under a withdrawn prefix answers this way.
      #
      # This pinned `{:upstream_refused, :auth}`, which was chosen for its
      # place in the router's failover set rather than for being true: `:auth`
      # is "this deployment does not hold the credential" everywhere else in
      # the package, and a withdrawn URL prefix is not a credential anyone can
      # hand us. The failover is unchanged; the reason now says what happened.
      assert {:error, {:source_unavailable, :endpoint}} = Backend.call(primary, :block_height)
    end

    test "the router fails over to the configured chicmoz instance" do
      # A threshold of one failure for this pair, so coverage is free to move
      # on the first bad answer. That it does not is the point of the 404 test
      # below, and here it is what an operator reads while it happens.
      {primary, fallback, _key} = pair(withdrawn(), breaker: [failure_threshold: 1])
      router = Router.new([primary, fallback])
      _ignored = drain()

      # Two sources, named apart. `[:aztec, :aztec]` would say that two are
      # believed healthy and not which of them is the temporary path, and
      # which one is the whole question during a revocation.
      assert Router.coverage(router, @chain)[:block_height] == [:aztecscan, :chicmoz]

      assert {:ok, %{height: 83_597}} = Router.call(router, @chain, :block_height)

      asked = hosts()
      assert Enum.any?(asked, &String.starts_with?(&1, "revoked-"))
      assert Enum.any?(asked, &String.starts_with?(&1, "chicmoz-"))

      # The survivor served the read and coverage still names both, because a
      # 404 records health: the report cannot narrow here, so the names are
      # the only part of it that moves with the failover.
      assert Router.coverage(router, @chain)[:block_height] == [:aztecscan, :chicmoz]
    end

    test "a 404 records no breaker failure, which is why the classification carries the failover" do
      # `Raxol.Web3.HTTP` records a 404 as health, by design: a definitive
      # answer about a missing thing is a healthy upstream. So health alone can
      # never move a revoked prefix off the front of the candidate list.
      {primary, _fallback, key} = pair(withdrawn())

      assert {:error, {:source_unavailable, :endpoint}} = Backend.call(primary, :block_height)

      assert CircuitBreaker.status(Tables.breakers(), key).failures == 0
    end

    test "a challenge response does record a breaker failure, and also fails over" do
      {primary, fallback, key} = pair(challenged())

      assert {:error, {:http, 403}} = Backend.call(primary, :block_height)
      assert CircuitBreaker.status(Tables.breakers(), key).failures == 1

      _ignored = drain()

      assert {:ok, %{height: 83_597}} =
               Router.call(Router.new([primary, fallback]), @chain, :block_height)

      assert Enum.any?(hosts(), &String.starts_with?(&1, "chicmoz-"))
    end

    test "an open breaker narrows coverage to the named survivor" do
      # The challenge shape, because it is the one that records a failure. At
      # a threshold of one the report goes from two sources to the one that is
      # left, and the transition is only legible because the two are named
      # apart.
      {primary, fallback, key} = pair(challenged(), breaker: [failure_threshold: 1])
      router = Router.new([primary, fallback])

      assert Router.coverage(router, @chain)[:block_height] == [:aztecscan, :chicmoz]

      assert {:error, {:http, 403}} = Backend.call(primary, :block_height)
      assert CircuitBreaker.status(Tables.breakers(), key).state == :open

      assert Router.coverage(router, @chain)[:block_height] == [:chicmoz]

      _ignored = drain()

      assert {:ok, %{height: 83_597}} = Router.call(router, @chain, :block_height)

      # The dial matches the report: the open source is not asked at all.
      assert [host] = hosts()
      assert String.starts_with?(host, "chicmoz-")
    end

    test "a 404 on an addressed endpoint is an answer, so the fallback is never asked" do
      # The other half of the split, and it is a routing decision rather than a
      # taste one: the fallback would answer the same thing about a hash that
      # does not exist, and asking it doubles the cost of every miss.
      {primary, fallback, _key} = pair(withdrawn())
      router = Router.new([primary, fallback])
      _ignored = drain()

      assert {:error, {:upstream_refused, :not_found}} =
               Router.call(router, @chain, :get_transaction, [@mined])

      refute Enum.any?(hosts(), &String.starts_with?(&1, "chicmoz-"))
    end
  end

  describe "against a real upstream" do
    # Generous bounds and an unmetered bucket, deliberately. What these prove
    # is that the dated claims in the moduledoc still hold, not that somebody
    # else's service is fast, and the seeded rate limit is a guess about their
    # budget rather than a property worth failing a build over.
    defp live do
      [
        cache: false,
        http_opts: [
          rate_limit: [capacity: 100, refill_per_second: 50.0],
          chunk_timeout_ms: 30_000,
          deadline_ms: 60_000
        ]
      ]
    end

    @tag :live_web3
    test "the temporary path still answers, and still identifies mainnet" do
      {:ok, handle} = Aztec.new(@chain, live())

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == @chain
      assert info.average_block_time_ms > 0
      assert info.total_transactions > 30_000
      assert info.total_blocks == nil
      assert info.total_addresses == nil

      assert {:ok, rollup} = Aztec.rollup(state(handle))
      assert rollup.network == "MAINNET"
      assert rollup.l1_chain_id == 1
      assert is_binary(rollup.rollup_version)
      assert {:evm, _rollup_address} = rollup.l1_rollup
      assert {:evm, _registry} = rollup.l1_registry
    end

    @tag :live_web3
    test "the unit claim re-probes: latest-height is a block number and slots outrun it" do
      {:ok, handle} = Aztec.new(@chain, live())

      assert {:ok, tips} = Aztec.tips(state(handle))
      assert tips.finalized <= tips.proven
      assert tips.proven <= tips.proposed

      # These two endpoints are deliberately not part of the backend:
      # `l2/latest-height` because `l2/tips` answers both halves of the height
      # at one moment, and the raw block because the block shape carries no
      # slot. The moduledoc's dated claims are about them, so the re-probe goes
      # through the guarded client directly rather than inventing a callback.
      base = "https://api.aztecscan.xyz/v1/temporary-api-key"
      opts = live()[:http_opts]

      assert {:ok, %{status: 200, body: body}} = HTTP.get(base <> "/l2/latest-height", opts)
      assert {latest, ""} = Integer.parse(String.trim(body))
      assert latest > 83_000

      # A bound rather than equality: the chain moves between two requests.
      assert abs(latest - tips.proposed) <= 5

      assert {:ok, %{status: 200, body: head}} = HTTP.get(base <> "/l2/blocks/latest", opts)
      assert {:ok, block} = Jason.decode(head)

      variables = block["header"]["globalVariables"]
      assert variables["blockNumber"] == String.to_integer(block["height"])
      assert variables["slotNumber"] > variables["blockNumber"]

      # The four-value ladder the moduledoc records, plus the transient it also
      # emits. A new value here is a drift worth a red test.
      assert block["nativeStatus"] in ~w(proposed checkpointed proven finalized unknown)
    end

    @tag :live_web3
    test "every declared callback answers against mainnet, and the absent ones stay absent" do
      {:ok, handle} = Aztec.new(@chain, live())

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :block
      assert height.height > 83_000
      assert height.finalized_height <= height.height
      assert height.indexer.finished? in [true, false]

      assert {:ok, tx} = Backend.call(handle, :get_transaction, [@mined])
      assert tx.hash == @mined
      assert tx.status == :success
      assert tx.from == nil

      assert {:ok, block} = Backend.call(handle, :get_block, [83_582])
      assert block.height == 83_582

      assert {:ok, metadata} = Backend.call(handle, :contract_metadata, [@instance])
      assert metadata.verified? == false

      assert {:error, {:unsupported, :token_balances}} =
               Backend.call(handle, :token_balances, [@instance, []])
    end
  end
end

defmodule Raxol.Web3.Backend.TronTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.TronHarness

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Tron

  # A Binance cold wallet, in both encodings, and they are the same account:
  # `Raxol.Web3.Tron.Address.to_hex/1` of the first is the second.
  @base58 "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @hex "41e28b3cfd4e0e909077821478e9fcb86b84be786e"

  @tx "ef3d8c0ab6c9d0624e0b7e72e2376924503bfd71d6990df33943254ed8d76938"

  describe "sources and chain references" do
    test "carries the measured session and concurrency facts as data" do
      sources = Tron.sources()

      assert sources.trongrid.concurrency == :pooled
      assert sources.trongrid.stateful?
      assert sources.trongrid.tools == 149

      assert sources.tronscan.concurrency == :serialized
      assert sources.tronscan.stateful?
      assert sources.tronscan.tools == 119

      assert sources.sqd.concurrency == :stateless
      refute sources.sqd.stateful?
    end

    test "accepts the registered CAIP-2 form and the alias, and canonicalizes" do
      assert {:ok, handle} = Tron.new(:sqd, chain_ref: "tron:mainnet")
      assert state(handle).chain_ref == "tron:0x2b6653dc"

      assert {:ok, other} = Tron.new(:sqd, chain_ref: "tron:0x2b6653dc")
      assert state(other).chain_ref == state(handle).chain_ref

      assert Tron.supported_chain_ids(state(handle)) == ["tron:0x2b6653dc"]
    end

    test "a stateful source refuses to build a handle without a client" do
      # The alternative would be a handle that looks usable and fails on first
      # read, and there is no honest default: this module opens no socket of
      # its own and `Raxol.MCP.Client` is the only sanctioned path to a session.
      assert {:error, :client_required} = Tron.new(:trongrid)
      assert {:error, :client_required} = Tron.new(:tronscan)
      assert {:ok, _handle} = Tron.new(:sqd)
    end

    test "the client spec carries the measured concurrency policy, not a default" do
      assert %{start: {_module, :start_link, [trongrid]}} = Tron.client_spec(:trongrid)
      assert Keyword.fetch!(trongrid, :concurrency) == :pooled
      assert Keyword.fetch!(trongrid, :url) == "https://mcp.trongrid.io/mcp"

      assert %{start: {_module, :start_link, [tronscan]}} = Tron.client_spec(:tronscan)
      assert Keyword.fetch!(tronscan, :concurrency) == :serialized
    end

    test "a handle names its source, while the module stays :tron" do
      # `backend/0` is the chain and is what config and a failover order are
      # keyed on, so it does not become per-source. `backend/1` is the handle,
      # and the two are different questions: without the second, three handles
      # over three upstreams are indistinguishable to everything that reports
      # on them.
      assert Tron.backend() == :tron

      for source <- [:trongrid, :tronscan] do
        handle = declared(source)
        assert Backend.name(handle) == source
      end

      assert Backend.name(sqd(%{})) == :sqd
    end
  end

  describe "capabilities" do
    test "the archive source declares nothing, and a read on it is refused" do
      handle = sqd(%{})

      assert Tron.capabilities(state(handle)) == []
      refute Backend.supports?(handle, :account_info)

      # Absent, not empty. An empty page from a source that cannot be asked the
      # question is the one shape a gate could read as "holds nothing".
      assert {:error, {:unsupported, :account_info}} =
               Backend.call(handle, :account_info, [{:tron, @base58}])

      assert {:error, {:unsupported, :list_transactions}} =
               Backend.call(handle, :list_transactions, [{:tron, @base58}, []])
    end

    test "the explorer source declines list_transactions and the node source declares it" do
      # Measured 2026-09-14: TronScan's account-scoped transaction tools take a
      # single `fromAddress` or `toAddress`, so "the transactions of this
      # address" would be two half-answers stitched together. TronGrid's
      # `getAccountTransactions` takes one address and answers both directions.
      trongrid = declared(:trongrid)
      tronscan = declared(:tronscan)

      assert Backend.supports?(trongrid, :list_transactions)
      refute Backend.supports?(tronscan, :list_transactions)
      assert Backend.supports?(tronscan, :list_token_transfers)
    end
  end

  # A handle that opens nothing, for the declarations alone. `capabilities/1`
  # and `supports?/2` read only the source, so a client is not needed to ask
  # what a source claims to answer.
  defp declared(source) do
    {:ok, handle} = Tron.new(source, client: self())
    handle
  end

  describe "block_height/1" do
    test "the node source takes finalized from the irreversible view, not the head" do
      handle = stateful(:trongrid, trongrid_height_routes())

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height == 86_236_775
      # `solidityGetBlock`, which is what the 25 `solidity*` tools are for. The
      # head fixture says 86,236,775 and the irreversible one 86,236,757, so a
      # backend that reported the head twice would fail here.
      assert height.finalized_height == 86_236_757
      assert height.finalized_height < height.height
      # No indexing status is published by this upstream, and a cheerful
      # `%{finished?: true}` would claim a component exists and is healthy.
      assert height.indexer == nil

      assert [{"getBlock", _}, {"solidityGetBlock", _}] = calls()
    end

    test "the explorer source takes finalized from the confirmed flag it publishes" do
      handle = stateful(:tronscan, %{"getBlocks" => "tronscan_blocks.sse"})

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height == 86_236_775
      # 18 blocks back at 19 confirmations, which is Tron's two-thirds-of-27
      # rule rather than a number this module chose.
      assert height.finalized_height == 86_236_757
      assert height.height - height.finalized_height == 18

      assert [{"getBlocks", %{"sort" => "-number"}}] = calls()
    end

    test "the archive source answers both halves and its own lag, in one call" do
      handle = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.finalized_height < height.height

      # Set what the upstream publishes and omit the rest: a lag in blocks and
      # in seconds, and no ratio at all, so `:indexed_ratio` is absent rather
      # than a fabricated 1.0 in the one field that exists so lag is visible.
      assert height.indexer.finished? == true
      assert height.indexer.lag_blocks == 20
      assert height.indexer.lag_seconds == 60
      refute Map.has_key?(height.indexer, :indexed_ratio)
    end

    test "a height is never cached, even on a handle that caches" do
      handle = stateful(:trongrid, trongrid_height_routes(), cache: true)

      assert {:ok, first} = Tron.block_height(state(handle))
      assert {:ok, ^first} = Tron.block_height(state(handle))

      # Four calls, not two. A cached height beside a live finalized height is
      # what produces `finalized_height > height`.
      assert length(calls()) == 4
    end
  end

  describe "chain_info/1" do
    test "the node source derives a block time from two real block timestamps" do
      # The head fixture is block 86,236,775 at 1,789,382,436,000 and the
      # sampled one is 86,236,675 at 1,789,382,136,000, so 300,000 ms over 100
      # blocks is 3,000 ms a block. Derived, not asserted: Tron's protocol
      # constant is 3 seconds and reporting that would be a number this module
      # claimed rather than one it read.
      handle = stateful(:trongrid, %{"getBlock" => &sampled_block/1})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.chain_ref == "tron:0x2b6653dc"
      assert info.average_block_time_ms == 3000.0
      # A node keeps no aggregate counters, and a fabricated total would read
      # as a fact about the chain.
      assert info.total_blocks == nil
      assert info.total_transactions == nil
      assert info.total_addresses == nil

      assert [{"getBlock", %{"detail" => false}}, {"getBlock", %{"id_or_num" => "86236675"}}] =
               calls()
    end

    test "a sample the node cannot answer leaves the block time absent" do
      # Both calls answer the head, so the derived interval is zero and the
      # honest answer is no answer rather than a zero block time.
      handle = stateful(:trongrid, %{"getBlock" => "trongrid_block.sse"})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.average_block_time_ms == nil
    end

    test "the explorer source answers the aggregate counters it publishes" do
      handle = stateful(:tronscan, %{"getStatsOverview" => "tronscan_stats_overview.sse"})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.average_block_time_ms == 3000
      assert info.total_blocks == 85_821_047
      assert info.total_transactions == 15_309_085_194
      assert info.total_addresses == 401_512_246
    end

    test "the archive source confirms the chain rather than asserting it" do
      handle = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})

      assert {:ok, info} = Tron.chain_info(state(handle))
      assert info.chain_ref == "tron:0x2b6653dc"
      assert info.average_block_time_ms == nil
      assert [{"portal_get_network_info", %{"network" => "tron-mainnet"}}] = calls()
    end
  end

  describe "the account reference accepts both encodings" do
    test "Base58 and hex for one account answer identically and ask identically" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:ok, from_base58} = Tron.account_info(state(handle), {:tron, @base58})
      assert {:ok, from_hex} = Tron.account_info(state(handle), {:tron, @hex})
      assert {:ok, from_prefixed_hex} = Tron.account_info(state(handle), {:tron, "0x" <> @hex})

      assert from_base58 == from_hex
      assert from_base58 == from_prefixed_hex
      assert from_base58.ref == {:tron, @base58}

      # And the same argument went upstream all three times. A cache key or a
      # rate-limit spend that differed by encoding is the bug this prevents,
      # and it is invisible in the return value alone.
      assert [
               {"getAccountInfo", %{"address" => @base58}},
               {"getAccountInfo", %{"address" => @base58}},
               {"getAccountInfo", %{"address" => @base58}}
             ] = calls()
    end

    test "a reference in another chain's tag is refused by its tag" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:error, {:unsupported_account_ref, :evm}} =
               Tron.account_info(state(handle), {:evm, "0x" <> @hex})

      assert {:error, {:unsupported_account_ref, :tron}} =
               Tron.account_info(state(handle), {:tron, "not-an-address"})

      assert calls() == []
    end

    test "the mapped account omits a kind and answers code presence" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:ok, account} = Tron.account_info(state(handle), {:tron, @base58})
      assert account.balance == 2_061_293_347_241_804
      assert account.contract? == false
      # Tron draws no account-kind distinction that changes how `balance` is
      # read, so the optional key is absent rather than nil.
      refute Map.has_key?(account, :kind)
    end

    test "malformed monetary integers are rejected instead of truncated" do
      for malformed <- ["12.5", "12sun"] do
        body = account_fixture_with_balance(malformed)
        handle = stateful(:trongrid, %{"getAccountInfo" => {:body, body}})

        assert {:error, {:decode_failed, :balance}} =
                 Tron.account_info(state(handle), {:tron, @base58})
      end
    end

    test "the explorer source answers the same account from its own shape" do
      handle = stateful(:tronscan, %{"getAccountDetail" => "tronscan_account_detail.sse"})

      assert {:ok, account} = Tron.account_info(state(handle), {:tron, @hex})
      assert account.ref == {:tron, @base58}
      assert account.balance == 2_061_293_347_241_804
      assert account.name == "Binance-Cold 2"
    end
  end

  describe "token_balances/3" do
    test "a TRC-10 and a TRC-20 balance both come back, distinguishable" do
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})

      assert {:ok, page} = Tron.token_balances(state(handle), {:tron, @base58}, [])

      trc10 = Enum.filter(page.items, &(&1.token.type == "TRC-10"))
      trc20 = Enum.filter(page.items, &(&1.token.type == "TRC-20"))

      assert length(trc10) == 2
      assert length(trc20) == 2

      # A TRC-10 asset is keyed by a numeric id and has no address to put in
      # `token()`'s `address`, so the id lands in `token_id` and the address is
      # absent rather than filled with the id.
      assert Enum.all?(trc10, &(&1.token.address == nil))
      assert Enum.all?(trc10, &(&1.token_id != nil))
      assert %{token_id: "1002721", amount: 10_000_000} = hd(trc10)

      # A TRC-20 is the other way round.
      assert Enum.all?(trc20, &(&1.token_id == nil))
      assert Enum.all?(trc20, &(&1.token.address != nil))
      assert %{token: %{address: "TSPigbpXYgt8JdgRmKew2SmJx41zymepb1"}} = hd(trc20)
      assert hd(trc20).amount == 100_000_000_000

      # One object, not a page, so there is no second page to walk.
      assert page.next == nil
    end

    test "the explorer source distinguishes the same two standards and the native asset" do
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_account_tokens.sse"})

      assert {:ok, page} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      assert [trc10, trc20] = page.items

      assert trc10.token.type == "TRC-10"
      assert trc10.token_id == "1002000"
      assert trc10.token.address == nil
      # This source publishes the scale, so a caller reaching it can interpret
      # the amount; the node source answers `nil` rather than guessing 18.
      assert trc10.token.decimals == 6
      assert trc10.token.symbol == "BTTOLD"

      assert trc20.token.type == "TRC-20"
      assert trc20.token_id == nil
      assert trc20.token.address == "TFczxzPhnThNSqr5by8tvxsdCFRRz6cPNq"
    end

    test "the native asset is neither standard" do
      # Measured 2026-09-14: TronScan reports TRX as `tokenType: "trc10"` with
      # `tokenId: "_"`. Passing that through would report the native balance as
      # a TRC-10 asset with an id of "_".
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      assert {:ok, page} = Tron.list_token_transfers(state(handle), {:tron, @base58})
      assert [transfer | _rest] = page.items
      assert transfer.token.type == "TRX"
      assert transfer.token.address == nil
    end
  end

  describe "the mapped transaction shapes" do
    test "the node source reports an absent block rather than inventing one" do
      handle = stateful(:trongrid, %{"getTransactionById" => "trongrid_transaction.sse"})

      assert {:ok, transaction} = Tron.get_transaction(state(handle), @tx)
      assert transaction.hash == @tx
      assert transaction.status == :success
      assert transaction.method == "TriggerSmartContract"
      assert transaction.from == {:tron, "TUzaRA8m8rkwMN1vYRWdzASSosdixZKdRB"}
      # The recorded response carried `owner_address` in Base58 and
      # `contract_address` in hex, in one object. Both come out canonical.
      assert transaction.to == {:tron, "TAFjULxiVgT4qWk6UZwjqwZXTSaGaqnVp4"}
      # `getTransactionInfoById` is the tool that carries a block and a fee, and
      # on 2026-09-14 it answered isError with its own output-schema validation
      # failure, so these are absent facts and TronScan is the source that has
      # them.
      assert transaction.block == nil
      assert transaction.fee == nil
    end

    test "the tool that would have carried the block is refused, not mapped" do
      # This is the measurement behind the nils above, pinned so it is visible
      # rather than folded into a comment: on 2026-09-14 `getTransactionInfoById`
      # answered `isError: true` with its own output-schema validation failure,
      # `/fee_major: string found, number expected`. A backend that reached for
      # it would get a refusal, and the text of that refusal must not travel.
      handle = stateful(:trongrid, %{"getTransactionById" => "trongrid_transaction_info.sse"})

      assert {:error, {:upstream_refused, :unknown} = reason} =
               Tron.get_transaction(state(handle), @tx)

      refute inspect(reason) =~ "fee_major"
      refute inspect(reason) =~ "outputSchema"
    end

    test "the explorer source answers the block and fee the node source cannot" do
      handle = stateful(:tronscan, %{"getTransactionDetail" => "tronscan_transaction.sse"})

      assert {:ok, transaction} = Tron.get_transaction(state(handle), @tx)
      assert transaction.hash == @tx
      assert transaction.status == :success
      assert transaction.block == 86_233_411
      assert transaction.fee == 0
      assert %DateTime{} = transaction.timestamp
    end

    test "a listed transaction carries the block and fee the by-hash read lacks" do
      handle =
        stateful(:trongrid, %{"getAccountTransactions" => "trongrid_account_transactions.sse"})

      assert {:ok, page} = Tron.list_transactions(state(handle), {:tron, @base58})
      assert [first, _second] = page.items
      assert first.block == 86_227_373
      assert first.status == :success
      assert first.method == "UnDelegateResourceContract"
      # A resource delegation names its counterparty `receiver_address`, which
      # is not a fallback for `to_address` but a different field in a different
      # contract type.
      assert first.to == {:tron, @base58}
    end

    test "a token transfer carries the metadata the transfer list publishes" do
      handle =
        stateful(:trongrid, %{
          "getAccountTrc20Transactions" => "trongrid_trc20_transactions.sse"
        })

      assert {:ok, page} = Tron.list_token_transfers(state(handle), {:tron, @base58})
      assert [first | _rest] = page.items
      assert first.token.symbol == "BTT"
      assert first.token.decimals == 18
      assert first.token.type == "TRC-20"
      assert first.amount == 3_000_000_000_000_000_000_000_000_000_000
      assert first.transaction == @tx
    end

    test "a block reads its height out of the header" do
      handle = stateful(:trongrid, %{"getBlock" => "trongrid_block.sse"})

      assert {:ok, block} = Tron.get_block(state(handle), 86_236_775)
      assert block.height == 86_236_775
      assert block.hash == "000000000523de676259ebe55b1a9ecd339d6bc7abb4c0f6cab97db0fc60899f"
      assert %DateTime{} = block.timestamp
      assert [{"getBlock", %{"id_or_num" => "86236775"}}] = calls()
    end
  end
end

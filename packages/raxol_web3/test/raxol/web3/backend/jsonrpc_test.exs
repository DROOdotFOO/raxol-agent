defmodule Raxol.Web3.Backend.JSONRPCTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.JSONRPCHarness

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.JSONRPC
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Router

  @eoa {:evm, "0xb754e001604508f841d768e64d38b7c98c859c05"}
  @token {:evm, "0x5317c0d077d2eeb639448939b930d49c4984b63b"}
  @hash "0x0b88f6bbaae329a1de198da8b14a3db03a9d1d5bb29345b116bb12fe64496839"
  @head 0x3BD25D0
  @robinhood "https://rpc.mainnet.chain.robinhood.com"
  @chain "eip155:4663"

  describe "chains" do
    test "chain 4663 has a default URL in library code, which is where it was missing" do
      # ADR-0033 gap 2: the only URL for this chain lived in a shell script.
      # Probed 2026-09-14, this endpoint answered eth_chainId with 0x1237.
      assert JSONRPC.default_urls() == %{4663 => @robinhood}
      assert {:ok, {JSONRPC, %{url: @robinhood, chain_id: 4663}}} = JSONRPC.new("eip155:4663")
    end

    test "an explicit url overrides the table" do
      assert {:ok, {JSONRPC, %{url: "https://node.test/"}}} =
               JSONRPC.new("eip155:4663", url: "https://node.test/")
    end

    test "a chain that was never probed needs a url rather than getting a guess" do
      # A table entry is a claim about a live endpoint on a date, so an absent
      # chain is an absent claim, not a default worth inventing.
      assert {:error, :no_rpc_url} = JSONRPC.new("eip155:1")
      assert {:error, {:unsupported_chain, _}} = JSONRPC.new("solana:mainnet")
    end

    test "a url that is not https is refused where it is configured, not where it is dialled" do
      assert {:error, :invalid_rpc_url} = JSONRPC.new("eip155:1", url: "http://node.test/")
      assert {:error, :invalid_rpc_url} = JSONRPC.new("eip155:1", url: "not a url")
    end
  end

  describe "capabilities" do
    test "declares what an eth_* allowlist can answer" do
      handle = handle(%{})

      for callback <- [:get_transaction, :account_info, :get_block, :read_contract, :raw_request] do
        assert Backend.supports?(handle, callback), "#{callback} is not declared"
      end

      assert Backend.supports?(handle, :get_logs)
    end

    test "the reads a node has no index for are absent, not stubbed" do
      # ADR-0039 decision 3: absence is the answer. This asserts absence rather
      # than an error shape on purpose, because a callback that existed and
      # returned {:error, {:unsupported, _}} would satisfy every assertion about
      # an error shape while being exactly the stub the rules forbid.
      #
      # get_transaction/2 sits on the other side of the same line and is
      # asserted here so the file says plainly which reads a node can and
      # cannot answer: a node has an index over transaction ids, and none over
      # accounts.
      Code.ensure_loaded!(JSONRPC)
      handle = handle(%{})
      declared = JSONRPC.capabilities(state(handle))

      assert :get_transaction in declared
      assert function_exported?(JSONRPC, :get_transaction, 2)

      for {callback, arity} <- [
            list_transactions: 3,
            token_balances: 2,
            list_token_transfers: 3,
            list_nfts: 3,
            contract_metadata: 2,
            resolve_name: 2
          ] do
        refute callback in declared, "#{callback} is declared"
        refute Backend.supports?(handle, callback)
        refute function_exported?(JSONRPC, callback, arity), "#{callback}/#{arity} exists"
      end
    end
  end

  describe "chain_info/1" do
    test "answers a chain reference and a derived block time, and nil for an indexer's counters" do
      handle =
        handle(%{
          "eth_chainId" => result("chain_id"),
          "eth_getBlockByNumber" => blocks()
        })

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "eip155:4663"

      # Two real timestamps 100 blocks apart: 0x6aa7c87a - 0x6aa7c86f is 11
      # seconds, so 110 ms a block. Derived, not decorative.
      assert info.average_block_time_ms == 110.0

      # A node keeps no aggregate counters, and nil is what it knows.
      assert info.total_blocks == nil
      assert info.total_transactions == nil
      assert info.total_addresses == nil
    end

    test "a url whose chain id disagrees with the handle is an error, not an answer" do
      # The test that catches 4663's handle pointed at chain 1, or the reverse.
      # Without it every callback here would answer, correctly, about a chain
      # nobody asked about.
      handle =
        handle(
          %{"eth_chainId" => result("chain_id"), "eth_getBlockByNumber" => blocks()},
          chain_ref: "eip155:1",
          url: "https://wrong-chain.test/"
        )

      assert {:error, {:blocked, :chain_mismatch}} = Backend.call(handle, :chain_info)

      # And it stops there: the identity check runs before anything is read.
      assert methods() == ["eth_chainId"]
    end

    test "a mismatch is terminal at the router, not a quiet failover" do
      # The consequence of classifying it as {:blocked, _}: failing over would
      # answer this caller from the next candidate and leave the misconfigured
      # handle in the router answering about the wrong chain forever. An error
      # is what gets it fixed.
      misconfigured =
        handle(
          %{"eth_chainId" => result("chain_id"), "eth_getBlockByNumber" => blocks()},
          chain_ref: "eip155:1",
          url: "https://wrong-chain.test/"
        )

      {:ok, well} = Stub.new("eip155:1", answers: %{chain_info: {:ok, %{marker: :stub}}})

      assert {:error, {:blocked, :chain_mismatch}} =
               Router.call(Router.new([misconfigured, well]), "eip155:1", :chain_info)
    end

    test "the block time is advisory: a node that cannot serve the sample still answers" do
      handle =
        handle(%{
          "eth_chainId" => result("chain_id"),
          "eth_getBlockByNumber" => fn
            ["latest", false] -> result("block")
            [_pruned, false] -> nil
          end
        })

      assert {:ok, %{average_block_time_ms: nil, chain_ref: "eip155:4663"}} =
               Backend.call(handle, :chain_info)
    end
  end

  describe "block_height/1" do
    test "both numbers come from the node, and there is no indexer to report" do
      handle =
        handle(%{
          "eth_blockNumber" => result("block_number"),
          "eth_getBlockByNumber" => blocks()
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.height == 0x3BD25DE
      assert height.finalized_height == 0x3BD05F0
      assert height.finalized_height <= height.height
      assert height.unit == :block

      # nil, not %{finished?: true}. There is no indexer here to be behind, and
      # inventing a healthy one would claim a component that does not exist.
      assert height.indexer == nil
    end

    test "a node that does not know the finalized tag reports nil rather than failing" do
      handle =
        handle(%{
          "eth_blockNumber" => result("block_number"),
          "eth_getBlockByNumber" => fn _params -> nil end
        })

      assert {:ok, %{height: 0x3BD25DE, finalized_height: nil}} =
               Backend.call(handle, :block_height)
    end
  end

  describe "get_transaction/2" do
    test "a mined transaction carries its status and its fee, both from the receipt" do
      handle =
        handle(%{
          "eth_getTransactionByHash" => result("transaction"),
          "eth_getTransactionReceipt" => result("receipt")
        })

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@hash])
      assert transaction.hash == @hash
      assert transaction.status == :success
      assert transaction.block == @head
      assert transaction.value == 0
      assert transaction.from == @eoa
      assert transaction.to == @token
      assert transaction.fee == 0x7099 * 0x43C59C0

      # The four-byte selector of approve(address,uint256): a node has no ABI,
      # so this is the whole of what it knows about the method.
      assert transaction.method == "0x095ea7b3"

      # A node's transaction record carries no timestamp, and the block that
      # does would be a third round trip for a field get_block/2 answers.
      assert transaction.timestamp == nil
    end

    test "a transaction the node holds but has not mined is :pending, not an error" do
      # The same record the node gave, minus the two fields a pooled
      # transaction has not got yet, and with no receipt: this is exactly what
      # a node answers between acceptance and inclusion.
      pooled = Map.merge(result("transaction"), %{"blockNumber" => nil, "blockHash" => nil})

      handle =
        handle(%{
          "eth_getTransactionByHash" => pooled,
          "eth_getTransactionReceipt" => nil
        })

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@hash])
      assert transaction.status == :pending
      assert transaction.block == nil
      assert transaction.fee == nil
    end

    test "a hash the node has never seen is a refusal about the question" do
      # Not a source error, so the router must not fail over on it: another
      # node would answer the same and hide the first answer.
      handle = handle(%{"eth_getTransactionByHash" => nil})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_transaction, [@hash])

      # And the receipt is never asked for, because there is nothing to receipt.
      assert methods() == ["eth_getTransactionByHash"]
    end
  end

  describe "account_info/2" do
    test "answers from a balance and a code read, which is all a node can offer" do
      handle =
        handle(%{
          "eth_getBalance" => result("balance"),
          "eth_getCode" => result("code_eoa")
        })

      assert {:ok, account} = Backend.call(handle, :account_info, [@eoa])
      assert account.ref == @eoa
      assert account.balance == 0xEAD018F86947B
      assert account.contract? == false

      # A node has no source and no name service, so these are false and nil
      # rather than absent or invented.
      assert account.verified? == false
      assert account.name == nil
      assert account.ens == nil

      assert methods() == ["eth_getBalance", "eth_getCode"]
    end

    test "contract? is code presence, which since EIP-7702 is not account type" do
      handle =
        handle(%{
          "eth_getBalance" => result("balance"),
          "eth_getCode" => result("code_contract")
        })

      assert {:ok, %{contract?: true}} = Backend.call(handle, :account_info, [@token])
    end
  end

  describe "get_block/2" do
    test "a number goes to eth_getBlockByNumber and a hash to eth_getBlockByHash" do
      hash = result("block")["hash"]

      handle =
        handle(%{
          "eth_getBlockByNumber" => fn ["0x3bd25d0", false] -> result("block") end,
          "eth_getBlockByHash" => fn [^hash, false] -> result("block") end
        })

      assert {:ok, block} = Backend.call(handle, :get_block, [@head])
      assert block.height == @head
      assert block.hash == hash
      assert %DateTime{} = block.timestamp
      assert block.miner == {:evm, "0xa4b000000000000000000073657175656e636572"}
      # Two, because the fixture is trimmed to two hashes of the block's eight.
      assert block.transactions_count == 2

      assert {:ok, ^block} = Backend.call(handle, :get_block, [hash])
      assert methods() == ["eth_getBlockByNumber", "eth_getBlockByHash"]
    end

    test "a block the node does not have is a refusal rather than an empty block" do
      handle = handle(%{"eth_getBlockByNumber" => fn _params -> nil end})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_block, [999_999_999])
    end
  end

  describe "web3_get_block over this backend" do
    # Through the served surface rather than the callback, because the bug was
    # at that boundary: the tool's schema types `number` as an integer and a
    # model sends a string, and this backend reads any non-hash binary as a
    # block TAG.
    defp tool_call(router, name, arguments) do
      Tools.tool_defs(router)
      |> Enum.find(&(&1.name == name))
      |> Map.fetch!(:callback)
      |> then(& &1.(arguments))
    end

    defp block_router do
      Router.new([
        handle(%{"eth_getBlockByNumber" => fn ["0x3bd25d0", false] -> result("block") end})
      ])
    end

    test "a block number sent as a string resolves the block an integer resolves" do
      router = block_router()

      assert {:ok, from_integer} =
               tool_call(router, "web3_get_block", %{"chain" => @chain, "number" => @head})

      assert {:ok, from_string} =
               tool_call(router, "web3_get_block", %{
                 "chain" => @chain,
                 "number" => Integer.to_string(@head)
               })

      assert from_integer == from_string

      # The proof is in what the node was asked: sent as a block tag,
      # `"62923728"` would be refused -32602 and classified as a final
      # `{:upstream_refused, :not_found}` for a block this node has.
      assert drain() == [
               {"eth_getBlockByNumber", ["0x3bd25d0", false]},
               {"eth_getBlockByNumber", ["0x3bd25d0", false]}
             ]
    end

    test "a reference that is neither a number nor a tag is an argument error" do
      router = block_router()

      assert {:error, %{code: "invalid_argument", detail: "number"}} =
               tool_call(router, "web3_get_block", %{"chain" => @chain, "number" => "next week"})

      # And it is refused here rather than spent on the node, which would
      # answer the same wrong `not_found` it answered for a real block.
      assert drain() == []
    end

    test "a tag still reaches the node as a tag" do
      router =
        Router.new([
          handle(%{"eth_getBlockByNumber" => fn ["latest", false] -> result("block") end})
        ])

      assert {:ok, _block} =
               tool_call(router, "web3_get_block", %{"chain" => @chain, "number" => "latest"})
    end
  end
end

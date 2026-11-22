defmodule Raxol.Web3.Backend.JSONRPCWireTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.JSONRPCHarness

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Backend.JSONRPC
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @eoa {:evm, "0xb754e001604508f841d768e64d38b7c98c859c05"}
  @token {:evm, "0x5317c0d077d2eeb639448939b930d49c4984b63b"}
  @head 0x3BD25D0
  @robinhood "https://rpc.mainnet.chain.robinhood.com"

  describe "get_logs/3" do
    # head 10, lookback 4, window 2: page one is blocks 7..8 and page two 9..10.
    defp paging_handle(opts \\ []) do
      handle(
        %{
          "eth_blockNumber" => "0xa",
          "eth_getLogs" => fn [%{"fromBlock" => from}] ->
            case from do
              "0x7" -> [Enum.at(result("logs"), 0)]
              "0x9" -> [Enum.at(result("logs"), 1)]
            end
          end
        },
        Keyword.merge([log_window: 2, log_lookback: 4], opts)
      )
    end

    test "pages forward, and the second page continues where the first stopped" do
      handle = paging_handle()

      assert {:ok, first} = Backend.call(handle, :get_logs, [@token, []])
      assert [%{address: address, topics: [_transfer | _rest]}] = first.items
      assert address == elem(@token, 1)
      assert is_binary(first.next)

      assert [{"eth_blockNumber", _}, {"eth_getLogs", [filter]}] = drain()

      assert filter == %{
               "address" => elem(@token, 1),
               "fromBlock" => "0x7",
               "toBlock" => "0x8"
             }

      assert {:ok, second} = Backend.call(handle, :get_logs, [@token, [cursor: first.next]])

      # The head is established once, by page one, and pinned into the cursor:
      # a walk that re-read it each page would chase a moving head forever.
      assert [{"eth_getLogs", [next_filter]}] = drain()
      assert next_filter["fromBlock"] == "0x9"
      assert next_filter["toBlock"] == "0xa"

      # The two recorded logs share a block and differ by index, which is what
      # distinguishes one page's item from the other's here.
      assert hd(second.items).index != hd(first.items).index
      # The walk ends at the head it was pinned to, so the last page has no cursor.
      assert second.next == nil
    end

    test "the cursor carries only the two numbers the walk is made of" do
      handle = paging_handle()
      origin = Origin.id(URI.new!("https://node.test/"))

      assert {:ok, %{next: cursor}} = Backend.call(handle, :get_logs, [@token, []])
      assert {:ok, params} = Cursor.decode(cursor, origin, :rpc_logs)
      assert params == %{"from_block" => 9, "to_block" => 10}
    end

    test "a cursor is refused on another endpoint and on another origin" do
      handle = paging_handle()
      origin = Origin.id(URI.new!("https://node.test/"))

      assert {:ok, %{next: cursor}} = Backend.call(handle, :get_logs, [@token, []])
      _first_walk = drain()

      assert {:error, :wrong_scope} = Cursor.decode(cursor, origin, :address_logs)

      elsewhere = paging_handle(url: "https://other-node.test/")

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(elsewhere, :get_logs, [@token, [cursor: cursor]])

      # Refused before a request is built, which is the point: a cursor's
      # contents become upstream query parameters.
      assert drain() == []
    end

    test "a request is bounded, because an unbounded range is how a node refuses" do
      handle =
        handle(
          %{
            "eth_blockNumber" => result("block_number"),
            "eth_getLogs" => fn _params -> [] end
          },
          log_window: 2_000,
          log_lookback: 10_000
        )

      assert {:ok, %{items: []}} = Backend.call(handle, :get_logs, [@token, []])

      assert [{"eth_blockNumber", _}, {"eth_getLogs", [filter]}] = drain()
      {:ok, from} = Raxol.Web3.RPC.decode_quantity(filter["fromBlock"])
      {:ok, to} = Raxol.Web3.RPC.decode_quantity(filter["toBlock"])
      assert to - from + 1 == 2_000
    end
  end

  describe "read_contract/2" do
    test "goes to eth_call, which is a read a challenge-gated explorer cannot serve" do
      handle = handle(%{"eth_call" => result("call")})

      assert {:ok, hex} =
               Backend.call(handle, :read_contract, [%{to: "0xabc", data: "0x18160ddd"}])

      assert hex == result("call")
    end
  end

  describe "raw_request/2" do
    test "passes an allowlisted method through" do
      handle = handle(%{"eth_chainId" => result("chain_id")})

      assert {:ok, "0x1237"} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])
    end

    test "refuses a method outside the allowlist before a request is built" do
      # The assertion that matters is the second one. A passthrough that
      # refused only in its return value would still have spent a token, opened
      # a socket and, for a write method, reached a node.
      handle = handle(%{"eth_chainId" => result("chain_id")})

      # The positive control, in the same test and against the same handle: an
      # allowlisted method does reach the seam, so the emptiness asserted below
      # is an observation and not a test that passes by never looking.
      assert {:ok, _chain_id} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])

      assert methods() == ["eth_chainId"]

      assert {:error, {:unsupported, :rpc_method}} =
               Backend.call(handle, :raw_request, [
                 %{method: "eth_sendRawTransaction", params: ["0xdeadbeef"]}
               ])

      assert drain() == []
    end

    test "a request that is not a method and params is refused the same way" do
      handle = handle(%{})

      assert {:error, {:unsupported, :rpc_method}} =
               Backend.call(handle, :raw_request, [%{method: :eth_chainId}])

      assert {:error, {:unsupported, :rpc_method}} = Backend.call(handle, :raw_request, [%{}])
      assert drain() == []
    end
  end

  describe "the headers an RPC post carries" do
    # A seam of its own, because `serving/1` reports the decoded body and this
    # is the one question asked about the request's headers.
    defp recording_seam(result) do
      fn _vetted, request, _opts ->
        send(self(), {:headers, request.headers})

        body = %{
          "jsonrpc" => "2.0",
          "id" => Jason.decode!(request.body)["id"],
          "result" => result
        }

        {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}
      end
    end

    defp authed(headers) do
      {:ok, handle} =
        JSONRPC.new("eip155:4663",
          url: "https://authed-node.test/",
          http_opts:
            [{:exchange, recording_seam(result("chain_id"))}, {:headers, headers}] ++ unmetered(),
          cache: false
        )

      handle
    end

    test "an operator-supplied header survives the JSON content type" do
      # `:http_opts` is documented as forwarded unchanged, and
      # `Raxol.Web3.RPC` replaced the list rather than merging it: a node
      # behind RBAC or an API key is reached only by the header the operator
      # configured, so every read through this backend answered 401 while the
      # configuration looked right.
      handle = authed([{"authorization", "Bearer operator-token"}])

      assert {:ok, "0x1237"} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])

      assert_receive {:headers, headers}
      assert {"authorization", "Bearer operator-token"} in headers
      assert {"content-type", "application/json"} in headers
    end

    test "the backend's content type wins a collision, and there is one of it" do
      # A duplicate `content-type` is refused outright by some servers, and a
      # JSON-RPC body is JSON whatever the operator wrote in its place.
      handle = authed([{"content-type", "text/plain"}, {"x-api-key", "k"}])

      assert {:ok, "0x1237"} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])

      assert_receive {:headers, headers}
      assert {"x-api-key", "k"} in headers

      assert Enum.filter(headers, fn {name, _value} -> name == "content-type" end) ==
               [{"content-type", "application/json"}]
    end
  end

  describe "the response cache" do
    # Own URLs, because the cache is per node and keyed by origin.
    test "a repeated account read is served from the cache" do
      handle =
        handle(
          %{"eth_getBalance" => result("balance"), "eth_getCode" => result("code_eoa")},
          cache: true,
          url: "https://cache-account.test/"
        )

      assert {:ok, first} = Backend.call(handle, :account_info, [@eoa])
      assert {:ok, ^first} = Backend.call(handle, :account_info, [@eoa])

      assert methods() == ["eth_getBalance", "eth_getCode"]
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle =
        handle(
          %{"eth_blockNumber" => result("block_number"), "eth_getBlockByNumber" => blocks()},
          cache: true,
          url: "https://cache-height.test/"
        )

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert Enum.count(methods(), &(&1 == "eth_blockNumber")) == 2
    end

    test "a refusal delivered inside a 200 is not cached, so the next read reaches the node" do
      # A node announces every refusal it has with HTTP 200 and an `error`
      # object, so a cache that decided by status stored refusals. -32005 is
      # the one that reads worst: a rate limit is a fact about a moment, and
      # the `:block` class is a minute, so one throttled read answered every
      # later read of that block as throttled long after the budget refilled.
      answers = :counters.new(1, [])

      handle =
        handle(
          %{
            "eth_getBlockByNumber" => fn _params ->
              :counters.add(answers, 1, 1)

              case :counters.get(answers, 1) do
                1 -> {:error, -32_005}
                _landed -> result("block")
              end
            end
          },
          cache: true,
          url: "https://cache-refusal.test/"
        )

      assert {:error, {:upstream_refused, :rate_limit}} =
               Backend.call(handle, :get_block, [@head])

      assert {:ok, %{height: @head}} = Backend.call(handle, :get_block, [@head])

      # Two requests: the second was not answered from the table.
      assert methods() == ["eth_getBlockByNumber", "eth_getBlockByNumber"]
    end

    test "a result is still cached, so refusing to cache refusals costs nothing else" do
      handle =
        handle(
          %{"eth_getBlockByNumber" => fn ["0x3bd25d0", false] -> result("block") end},
          cache: true,
          url: "https://cache-block.test/"
        )

      assert {:ok, first} = Backend.call(handle, :get_block, [@head])
      assert {:ok, ^first} = Backend.call(handle, :get_block, [@head])

      assert methods() == ["eth_getBlockByNumber"]
    end
  end

  describe "refusals" do
    test "a JSON-RPC error object becomes a class, and its message stays upstream" do
      handle = handle(%{"eth_chainId" => {:error, -32_005}})

      assert {:error, {:upstream_refused, :rate_limit}} = Backend.call(handle, :chain_info)
    end

    test "a body that is not JSON-RPC is a decode failure, not a crash" do
      exchange = fn _vetted, _request, _opts ->
        {:ok, %{status: 200, headers: [], body: "<html>challenge</html>"}}
      end

      {:ok, handle} =
        JSONRPC.new("eip155:4663",
          url: "https://not-json.test/",
          http_opts: [{:exchange, exchange} | unmetered()],
          cache: false
        )

      assert {:error, {:decode_failed, :json}} = Backend.call(handle, :chain_info)
    end
  end

  describe "chain 4663 routes" do
    test "a breakered explorer orders behind the node, and the node answers" do
      # Issue #1026's third acceptance item, and the point of this backend.
      # Before ADR-0039 this router had one candidate and no fallback: the only
      # explorer for this chain answered 403 with cf-mitigated: challenge on
      # 2026-09-13, and a raw node could not be expressed as a backend at all.
      {:ok, blockscout} = Blockscout.new("eip155:4663", cache: false)

      node =
        handle(%{
          "eth_blockNumber" => result("block_number"),
          "eth_getBlockByNumber" => blocks(),
          "eth_getBalance" => result("balance"),
          "eth_getCode" => result("code_eoa")
        })

      router = Router.new([blockscout, node])
      health = Backend.health_key(blockscout)

      # This chain has exactly one explorer, so its breaker key is fixed rather
      # than per-test, and the sibling test below trips the same one. Reset it
      # here, or whichever of the two runs second inherits the other's health
      # and this assertion passes or fails on the seed.
      CircuitBreaker.reset(Tables.breakers(), health)

      assert [{Blockscout, _} | _rest] = Router.candidates(router, "eip155:4663", :block_height)

      CircuitBreaker.record_failure(Tables.breakers(), health, failure_threshold: 1)

      assert [{JSONRPC, _} | _demoted] =
               Router.candidates(router, "eip155:4663", :block_height)

      # Answered by the node, and the shape says so: an explorer reports an
      # indexer and this reports nil, because there is no indexer here.
      assert {:ok, height} = Router.call(router, "eip155:4663", :block_height)
      assert height.height == 0x3BD25DE
      assert height.indexer == nil

      assert {:ok, account} = Router.call(router, "eip155:4663", :account_info, [@eoa])
      assert account.balance == 0xEAD018F86947B
      assert account.ens == nil
    end

    test "coverage reports the partial shape rather than the declared one" do
      # What an operator gets instead of a per-call error: with the explorer
      # breakered open, the chain keeps the reads a node can serve and loses
      # the ones that need an index over accounts.
      {:ok, blockscout} = Blockscout.new("eip155:4663", cache: false)
      node = handle(%{})
      router = Router.new([blockscout, node])

      CircuitBreaker.record_failure(Tables.breakers(), Backend.health_key(blockscout),
        failure_threshold: 1
      )

      coverage = Router.coverage(router, "eip155:4663")

      assert coverage[:block_height] == [:jsonrpc]
      assert coverage[:account_info] == [:jsonrpc]
      assert coverage[:read_contract] == [:jsonrpc]
      assert coverage[:raw_request] == [:jsonrpc]

      refute Map.has_key?(coverage, :list_transactions)
      refute Map.has_key?(coverage, :token_balances)
      refute Map.has_key?(coverage, :resolve_name)
    end
  end

  describe "against a real upstream" do
    # Generous bounds, and no assertion on elapsed time: what this proves is
    # that the default URL is live and that the chain id is what the table
    # claims, not that somebody else's node is fast.
    @tag :live_web3
    test "the default URL answers, and 4663 is the chain the table says it is" do
      {:ok, handle} =
        JSONRPC.new("eip155:4663",
          cache: false,
          http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]
        )

      assert state(handle).url == @robinhood

      assert {:ok, "0x1237"} =
               Backend.call(handle, :raw_request, [%{method: "eth_chainId", params: []}])

      # chain_info/1 runs the same comparison internally, so this answering at
      # all is the identity check passing against the live node.
      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "eip155:4663"
      assert info.total_blocks == nil
      assert is_number(info.average_block_time_ms)
      assert info.average_block_time_ms > 0

      # 0x3bd25de was the head on 2026-09-14, so the chain can only be past it.
      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :block
      assert height.height >= 0x3BD25DE
      assert height.finalized_height <= height.height
      assert height.indexer == nil
    end
  end
end

defmodule Raxol.Web3.Backend.SolanaReadsTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.SolanaHarness

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Solana
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Router
  alias Raxol.Web3.Scope

  @mainnet "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"

  # A real mainnet wallet, its fee-payer transaction, one of its token accounts,
  # a mint, a program and a sysvar. Every one was read live on 2026-09-14 and
  # every fixture below is that read, trimmed to two items per page.
  @wallet {:solana, "9RAufBfjGQjDfrwxeyKmZWPADHSb8HcoqCdrmpqvCr1g"}
  @program {:solana, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"}

  @signature "47H9XKQW8LTEhRUdEWXPPS1ZKHjoyfbUaFkF8PpmBVLKsFucVMMAmG39Vaw2XiktFL7swbNZxJ6ze4aCrAztM9F5"

  describe "list_transactions/3 and the signature cursor" do
    test "a page mints a cursor that decodes to the upstream's own parameter" do
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert length(page.items) == 2
      assert is_binary(page.next)

      origin = Scope.id("https://api.mainnet-beta.solana.com/")
      assert {:ok, params} = Cursor.decode(page.next, origin, :solana_address_signatures)

      # The last signature of the page, which is what `before` takes.
      assert params["before"] ==
               "38gvbbjChiHatnNaUhYxoma7gHuwLiKkUCPmFpDWQQuB9MsN7h52LgJr452FDAbcHvNvZUkFtrmuoiHB86B17gCS"

      assert Map.keys(params) == ["before"]
    end

    test "a cursor becomes the before parameter on the next request" do
      handle =
        rpc(%{
          "getSignaturesForAddress" => fixture("rpc_signatures.json"),
          "getSignaturesForAddress:before" => fixture("rpc_signatures_page2.json")
        })

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@wallet, []])
      _first = drain()

      assert {:ok, _page} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: cursor]])

      assert [%{"params" => [_pubkey, config]}] = requested_bodies()

      assert config["before"] ==
               "38gvbbjChiHatnNaUhYxoma7gHuwLiKkUCPmFpDWQQuB9MsN7h52LgJr452FDAbcHvNvZUkFtrmuoiHB86B17gCS"

      assert config["limit"] == 100
    end

    test "the second page is the upstream's own next page, and the two are disjoint" do
      # Both pages were recorded live on 2026-09-14, the second by handing the
      # first page's last signature back as `before`. Two pages of two for one
      # mainnet account returned four distinct signatures, which is what makes
      # the single-key allowlist sufficient.
      handle =
        rpc(%{
          "getSignaturesForAddress" => fixture("rpc_signatures.json"),
          "getSignaturesForAddress:before" => fixture("rpc_signatures_page2.json")
        })

      assert {:ok, first} = Backend.call(handle, :list_transactions, [@wallet, []])

      assert {:ok, second} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: first.next]])

      hashes = fn page -> page.items |> Enum.map(& &1.hash) |> MapSet.new() end

      assert MapSet.size(hashes.(first)) == 2
      assert MapSet.disjoint?(hashes.(first), hashes.(second))

      # The walk moves: a second page mints a different cursor from the first.
      assert second.next != first.next
    end

    test "the rows are thin, because a signature listing carries no counterparties" do
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert [row | _rest] = page.items

      assert row.status == :success
      assert row.block == 446_951_768
      assert %DateTime{} = row.timestamp
      # Filling `from` with the queried address would be a guess: an address a
      # transaction merely mentions is not its fee payer.
      assert row.from == nil
      assert row.to == nil
      assert row.fee == nil
    end

    test "only an empty page ends the walk, because the upstream flags no end" do
      handle = rpc(%{"getSignaturesForAddress" => ~s({"jsonrpc":"2.0","id":1,"result":[]})})

      assert {:ok, %{items: [], next: nil}} =
               Backend.call(handle, :list_transactions, [@wallet, []])
    end

    test "a cursor minted for another endpoint is refused before the request is built" do
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      origin = Scope.id("https://api.mainnet-beta.solana.com/")
      foreign = Cursor.encode(%{"block_number" => 1}, origin, :address_transactions)

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: foreign]])

      assert [] == requested_tools()
    end
  end

  describe "get_block/2, where a skipped slot is a success" do
    test "a produced slot carries its hash and its transaction count" do
      handle = rpc(%{"getBlock" => fixture("rpc_block.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [446_800_611])
      assert block.hash == "8kLEYsgop9R6kx6P6gHDTG4Zm83468Vjnyx4hsExyLbX"
      assert block.transactions_count == 2
      assert %DateTime{} = block.timestamp
      # getBlock exposes no leader identity.
      assert block.miner == nil
    end

    test "height is the slot asked for, never the upstream's blockHeight" do
      # The recorded response carries blockHeight 424,843,204 for slot
      # 446,800,611. Reporting that as `height` would make get_block/2 and
      # block_height/1 disagree by about 21.96 million while both claim
      # unit: :slot.
      handle = rpc(%{"getBlock" => fixture("rpc_block.json")})

      assert {:ok, %{height: 446_800_611}} = Backend.call(handle, :get_block, [446_800_611])
    end

    test "an empty slot is a success with a hash and a zero count" do
      handle = rpc(%{"getBlock" => fixture("rpc_block_empty.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [446_800_611])
      assert is_binary(block.hash)
      assert block.transactions_count == 0
    end

    test "a skipped slot is a success with no hash at all" do
      # JSON-RPC -32009, measured on slot 446,800,612, a real gap in getBlocks
      # over 446,800,612..446,800,615 on 2026-09-14. The nil hash is the
      # discriminator: a produced block always carries one, including slot
      # 1000, whose blockHeight is null.
      handle = rpc(%{"getBlock" => fixture("rpc_block_skipped.json")})

      assert {:ok, block} = Backend.call(handle, :get_block, [446_800_612])
      assert block.height == 446_800_612
      assert block.hash == nil
      assert block.timestamp == nil
      assert block.transactions_count == nil
    end

    test "a slot above the head is a failed read, not a skipped slot" do
      # -32004 rather than -32009, which is the whole reason the three
      # outcomes are distinguishable without a heuristic.
      handle = rpc(%{"getBlock" => fixture("rpc_block_unavailable.json")})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_block, [999_999_999])
    end

    test "a slot that is not a number is refused before any request" do
      handle = rpc(%{"getBlock" => fixture("rpc_block.json")})

      assert {:error, {:decode_failed, :slot}} = Backend.call(handle, :get_block, ["latest"])
      assert [] == requested_tools()
    end
  end

  describe "the response cache" do
    # Own origins, because the cache is per node and keyed by origin: sharing
    # the real hosts with the rest of this file would mean sharing entries.
    test "a repeated read is served from the cache and the upstream is asked once" do
      handle =
        rpc(%{"getEpochInfo" => fixture("rpc_epoch_info.json")},
          cache: true,
          url: "https://cache-one.solana.test/"
        )

      assert {:ok, first} = Backend.call(handle, :chain_info)
      assert {:ok, second} = Backend.call(handle, :chain_info)

      assert first == second
      assert [_one] = requested_tools()
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle =
        rpc(
          %{
            "getSlot:processed" => fixture("rpc_slot_processed.json"),
            "getSlot:finalized" => fixture("rpc_slot_finalized.json")
          },
          cache: true,
          url: "https://cache-two.solana.test/"
        )

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert length(requested_tools()) == 4
    end

    test "the catalog is cached, so resolution costs one request per hour" do
      handle =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          cache: true,
          url: "https://cache-three.sqd.test/mcp"
        )

      assert {:ok, _first} = Backend.call(handle, :chain_info)
      assert {:ok, _second} = Backend.call(handle, :chain_info)

      assert Enum.count(requested_tools(), &(&1 == "portal_list_networks")) == 1
    end

    # The three below share one origin between two handles on purpose: the
    # cache is keyed by `{origin_id, fragment}` and outlives a handle, so the
    # second handle reads the first handle's table. That is the only way to
    # ask "was the first answer stored" without reaching into the table.
    test "a tool error is not cached, so one bad catalog read does not answer for the hour" do
      # `resolve/1` runs before every SQD read and `:catalog` holds its answer
      # for an hour. The refusal arrives as HTTP 200 with `isError: true`, so
      # a cache that decided by status stored it, and one transient tool error
      # then answered every SQD read on this chain for the rest of that hour
      # while the portal was already serving again.
      url = "https://cache-catalog.sqd.test/mcp"
      broken = %{"portal_list_networks" => sse_error(%{"error" => %{"code" => "internal_error"}})}

      assert {:error, {:upstream_refused, :unknown}} =
               Backend.call(sqd(broken, cache: true, url: url), :chain_info)

      recovered =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          cache: true,
          url: url
        )

      assert {:ok, _info} = Backend.call(recovered, :chain_info)
    end

    test "a slot the node does not have yet is not cached, so the next read sees it land" do
      # -32004 for a slot at the head is a fact about this moment, and the
      # `:block` class is a minute. Recorded 2026-09-14.
      url = "https://cache-unavailable.solana.test/"
      slot = 999_999_999

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(
                 rpc(%{"getBlock" => fixture("rpc_block_unavailable.json")},
                   cache: true,
                   url: url
                 ),
                 :get_block,
                 [slot]
               )

      landed = rpc(%{"getBlock" => fixture("rpc_block.json")}, cache: true, url: url)

      assert {:ok, %{height: ^slot}} = Backend.call(landed, :get_block, [slot])
    end

    test "a skipped slot is cached, because it is permanent rather than a refusal" do
      # -32009 is the one error code this chain answers that is a fact about
      # the chain: slot 446,800,612 was skipped and always will have been. It
      # is a success here, so it is worth a minute in the table, and not
      # caching it would cost a request per read of every gap in the ledger.
      url = "https://cache-skipped.solana.test/"
      slot = 446_800_612

      assert {:ok, %{hash: nil}} =
               Backend.call(
                 rpc(%{"getBlock" => fixture("rpc_block_skipped.json")}, cache: true, url: url),
                 :get_block,
                 [slot]
               )

      _ignored = drain()
      produced = rpc(%{"getBlock" => fixture("rpc_block.json")}, cache: true, url: url)

      assert {:ok, %{hash: nil}} = Backend.call(produced, :get_block, [slot])
      assert [] == requested_tools()
    end
  end

  describe "no upstream prose escapes" do
    test "the model-facing answer text reaches no normalized field" do
      # portal_get_head returns answer: "Current value: 446,956,167." beside
      # the structured number, and portal_get_network_info returns a
      # display_name its own _tool_contract marks untrusted. Neither may travel.
      handle =
        sqd(%{
          "portal_get_head:latest" => fixture("sqd_head_latest.sse"),
          "portal_get_head:finalized" => fixture("sqd_head_finalized.sse"),
          "portal_get_network_info" => fixture("sqd_network_info.sse")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert {:ok, info} = Backend.call(handle, :chain_info)

      for term <- [height, info] do
        rendered = inspect(term, limit: :infinity)
        refute rendered =~ "Current value"
        refute rendered =~ "looks caught up"
        refute rendered =~ "Solana looks"
        refute rendered =~ "display_name"
      end
    end
  end

  describe "a router built as [sqd, rpc]" do
    defp router_pair(sqd_responses, rpc_responses) do
      Router.new([
        sqd(sqd_responses),
        rpc(rpc_responses)
      ])
    end

    test "the fallback answers what the primary does not declare" do
      # get_transaction/2 and account_info/2 are both absent from the SQD
      # handle, so the router walks past it without a request being made.
      router =
        router_pair(
          %{},
          %{
            "getTransaction" => fixture("rpc_transaction.json"),
            "getAccountInfo" => fixture("rpc_account_info_wallet.json")
          }
        )

      assert {:ok, transaction} =
               Router.call(router, @mainnet, :get_transaction, [@signature])

      assert transaction.hash == @signature

      assert {:ok, %{kind: :wallet}} = Router.call(router, @mainnet, :account_info, [@wallet])

      # Neither call touched the archive: no portal tool was asked.
      refute Enum.any?(requested_tools(), &String.starts_with?(&1, "portal_"))
    end

    test "the fallback answers a required callback the primary fails" do
      # A network the archive does not serve is {:unsupported_chain, _}, which
      # the router treats as a source error, so chain_info walks on to the node
      # rather than failing. Both handles are required to answer this callback,
      # so this is failover rather than absence.
      router =
        Router.new([
          sqd(%{}, network: "solana-unlisted"),
          rpc(%{"getEpochInfo" => fixture("rpc_epoch_info.json")})
        ])

      assert {:ok, info} = Router.call(router, @mainnet, :chain_info)
      assert info.total_blocks == 424_994_262

      tools = requested_tools()
      assert "portal_list_networks" in tools
      assert "getEpochInfo" in tools
    end

    test "a credential the archive wants and this deployment lacks walks on" do
      # `unauthorized` is a fact about the SOURCE, not about the question: the
      # node holds no credential and answers anyway. Reading it as
      # `{:upstream_refused, :unknown}` made it final, so a keyless archive
      # read died with a healthy node sitting behind it, while the identical
      # read on `Raxol.Web3.Backend.Tron` failed over.
      router =
        router_pair(
          %{"portal_get_network_info" => sse_error(%{"error" => %{"code" => "unauthorized"}})},
          %{"getEpochInfo" => fixture("rpc_epoch_info.json")}
        )

      assert {:ok, info} = Router.call(router, @mainnet, :chain_info)
      assert info.total_blocks == 424_994_262

      tools = requested_tools()
      assert "portal_get_network_info" in tools
      assert "getEpochInfo" in tools
    end

    test "the primary answers a required callback when it can, and the node is not asked" do
      router =
        router_pair(
          %{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          %{"getEpochInfo" => fixture("rpc_epoch_info.json")}
        )

      assert {:ok, info} = Router.call(router, @mainnet, :chain_info)
      assert info.total_blocks == 446_951_620
      refute "getEpochInfo" in requested_tools()
    end

    test "coverage names the sources, which is where the asymmetry is legible" do
      router = router_pair(%{}, %{})
      coverage = Router.coverage(router, @mainnet)

      # Both sources answer the required two, and each says which it is.
      assert coverage[:chain_info] == [:solana_sqd, :solana_rpc]
      assert coverage[:block_height] == [:solana_sqd, :solana_rpc]

      # The node alone answers each of these five, and coverage says so by
      # name rather than leaving an operator to read it off a count of one.
      for callback <- [
            :get_transaction,
            :account_info,
            :token_balances,
            :list_transactions,
            :get_block
          ] do
        assert coverage[callback] == [:solana_rpc], "#{callback} should be the node's alone"
      end

      # And nothing answers these: absence is the answer, per ADR-0039.
      for callback <- [
            :list_token_transfers,
            :read_contract,
            :contract_metadata,
            :get_logs,
            :resolve_name,
            :list_nfts,
            :raw_request
          ] do
        refute Map.has_key?(coverage, callback), "#{callback} must be absent from coverage"
      end
    end

    test "each handle names its own source while the module still names itself" do
      # `coverage/2` can only separate the two because the handles do:
      # `backend/1` answers per handle and `backend/0` is unchanged, so logs
      # and the `:source` config key still read :solana. Before the callback
      # existed both handles reported :solana, and coverage read
      # [:solana, :solana], a count of surviving sources that never said which
      # one had dropped out.
      router = router_pair(%{}, %{})

      assert [{Solana, %{source: :sqd}} = archive, {Solana, %{source: :rpc}} = node] =
               Router.candidates(router, @mainnet, :chain_info)

      assert Backend.name(archive) == :solana_sqd
      assert Backend.name(node) == :solana_rpc
      assert Solana.backend() == :solana

      # And `candidates/3` returns the handles themselves, which is where the
      # asymmetry is visible as the handle that answers rather than as a name.
      assert [{Solana, %{source: :rpc}}] =
               Router.candidates(router, @mainnet, :account_info)
    end
  end

  describe "against the real upstreams" do
    # Generous bounds, deliberately. What these prove is that the callbacks
    # answer and that a cursor pages, not that a third party is fast. Nothing
    # here asserts on elapsed time.
    defp live(source, opts \\ []) do
      {:ok, handle} =
        Solana.new(
          @mainnet,
          [source: source, http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]] ++ opts
        )

      handle
    end

    @tag :live_web3
    test "the archive answers the required two, in slots" do
      handle = live(:sqd)

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == @mainnet
      assert info.total_blocks > 400_000_000

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.height > 400_000_000
      assert height.finalized_height <= height.height
      assert height.indexer.finished? == true
      assert is_integer(height.indexer.lag_blocks)
    end

    @tag :live_web3
    test "a network the archive does not serve is refused, not failed" do
      handle = live(:sqd, network: "solana-not-a-network")

      assert {:error, {:unsupported_chain, "solana-not-a-network"}} =
               Backend.call(handle, :chain_info)
    end

    @tag :live_web3
    test "the node answers the required two plus every optional it declares" do
      handle = live(:rpc)

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.total_blocks > 400_000_000

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.finalized_height <= height.height

      assert {:ok, account} = Backend.call(handle, :account_info, [@wallet])
      assert account.kind == :wallet
      assert is_integer(account.balance)

      assert {:ok, %{kind: :program, contract?: true}} =
               Backend.call(handle, :account_info, [@program])

      assert {:ok, tokens} = Backend.call(handle, :token_balances, [@wallet, []])
      assert tokens.next == nil

      assert {:ok, page} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert page.items != []

      # The transaction the listing just named, so this needs no pinned
      # signature that could be pruned from the node's history.
      assert {:ok, transaction} =
               Backend.call(handle, :get_transaction, [hd(page.items).hash])

      assert transaction.hash == hd(page.items).hash
      assert {:solana, _payer} = transaction.from

      assert {:ok, block} = Backend.call(handle, :get_block, [transaction.block])
      assert block.height == transaction.block
      assert is_binary(block.hash)
    end

    @tag :live_web3
    test "a cursor pages forward against the live node" do
      handle = live(:rpc)

      assert {:ok, first} = Backend.call(handle, :list_transactions, [@wallet, []])

      assert {:ok, next} =
               Backend.call(handle, :list_transactions, [@wallet, [cursor: first.next]])

      assert hd(first.items).hash != hd(next.items).hash
    end
  end
end

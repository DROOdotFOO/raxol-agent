defmodule Raxol.Web3.Backend.SolanaTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.SolanaHarness

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Solana

  @mainnet "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"

  # A real mainnet wallet, its fee-payer transaction, one of its token accounts,
  # a mint, a program and a sysvar. Every one was read live on 2026-09-14 and
  # every fixture below is that read, trimmed to two items per page.
  @wallet {:solana, "9RAufBfjGQjDfrwxeyKmZWPADHSb8HcoqCdrmpqvCr1g"}
  @token_account {:solana, "C9VyXs6MPM8RgwouCH8qXih423VnraZBgzCNUepvC3xA"}
  @mint {:solana, "NkfbyG7feH9aJhdnSs4d7D7kWCEnxrmNUbM7dbpC6MM"}
  @program {:solana, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"}
  @sysvar {:solana, "SysvarC1ock11111111111111111111111111111111"}

  @signature "47H9XKQW8LTEhRUdEWXPPS1ZKHjoyfbUaFkF8PpmBVLKsFucVMMAmG39Vaw2XiktFL7swbNZxJ6ze4aCrAztM9F5"

  describe "chain references" do
    test "the alias canonicalizes on ingest, so a handle reports one reference" do
      # `solana:mainnet` is what a caller writes
      # and the truncated genesis hash is what CAIP-2 says. Measured
      # 2026-09-14, getGenesisHash returned
      # 5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d.
      assert {:ok, {Solana, %{chain_ref: @mainnet}}} = Solana.new("solana:mainnet")
      assert {:ok, {Solana, %{chain_ref: @mainnet}}} = Solana.new(@mainnet)
      assert Solana.chain_aliases()["solana:mainnet"] == @mainnet
    end

    test "each source gets its own endpoint, which is what makes them two handles" do
      assert {:ok, {Solana, %{source: :sqd, url: sqd_url}}} =
               Solana.new(@mainnet, source: :sqd)

      assert {:ok, {Solana, %{source: :rpc, url: rpc_url}}} =
               Solana.new(@mainnet, source: :rpc)

      assert sqd_url == "https://portal.sqd.dev/mcp"
      assert rpc_url == "https://api.mainnet-beta.solana.com"
    end

    test "an unknown source is refused at construction" do
      # `:unsupported_source`, the name `Raxol.Web3.Backend.Tron` already
      # used for the same fact. Two spellings of one reason is how a caller
      # ends up matching on one of them.
      assert {:error, {:unsupported_source, :helius}} = Solana.new(@mainnet, source: :helius)
    end
  end

  describe "capabilities" do
    test "the archive declares nothing optional, and that is the asymmetry" do
      # Measured 2026-09-14: no tool in SQD's 31 takes a Solana signature, and
      # its account tool is a look-back summary rather than a balance. So four
      # callbacks are absent rather than stubbed, per ADR-0039 decision 3.
      handle = sqd(%{})

      assert Solana.capabilities(state(handle)) == []

      for callback <- [:get_transaction, :account_info, :token_balances, :list_transactions] do
        refute Backend.supports?(handle, callback), "#{callback} must not be declared on SQD"
      end

      assert {:error, {:unsupported, :get_transaction}} =
               Backend.call(handle, :get_transaction, [@signature])

      assert {:error, {:unsupported, :account_info}} =
               Backend.call(handle, :account_info, [@wallet])
    end

    test "the node declares the five reads it can answer" do
      handle = rpc(%{})

      for callback <- [
            :get_transaction,
            :account_info,
            :token_balances,
            :list_transactions,
            :get_block
          ] do
        assert Backend.supports?(handle, callback), "#{callback} is not declared on RPC"
      end
    end

    test "raw_request and list_token_transfers are declined on both sources" do
      # raw_request keeps read-only structural rather than policed: with no
      # method parameter crossing the surface there is no allowlist to get
      # wrong. list_token_transfers is the cost demotion: a transfer here is an
      # instruction inside a transaction and neither source parses one.
      for handle <- [sqd(%{}), rpc(%{})] do
        refute Backend.supports?(handle, :raw_request)
        refute Backend.supports?(handle, :list_token_transfers)

        assert {:error, {:unsupported, :list_token_transfers}} =
                 Backend.call(handle, :list_token_transfers, [@wallet, []])
      end
    end
  end

  describe "network resolution" do
    test "the supported set is read at runtime, never hardcoded" do
      handle = sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")})

      assert {:ok, _info} = Backend.call(handle, :chain_info)

      assert ["portal_list_networks", "portal_get_network_info"] = requested_tools()
    end

    test "an alias in the live catalog resolves without a table here to drift" do
      # The catalog reports solana-mainnet's aliases as solana-beta, solana and
      # sol, measured 2026-09-14. A handle pointed at the alias resolves to the
      # canonical network name and queries that.
      handle =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")}, network: "solana")

      assert {:ok, _info} = Backend.call(handle, :chain_info)

      assert [_catalog, %{"params" => %{"arguments" => %{"network" => "solana-mainnet"}}}] =
               requested_bodies()
    end

    test "a network the catalog does not list is unsupported_chain, not a failed request" do
      handle =
        sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")},
          network: "solana-unlisted"
        )

      assert {:error, {:unsupported_chain, "solana-unlisted"}} = Backend.call(handle, :chain_info)

      # The catalog was asked and the tool was not: the refusal is decided
      # against the resolved set rather than by letting the request fail.
      assert ["portal_list_networks"] = requested_tools()
    end

    test "a stale catalog is caught by the tool's own refusal, with the same term" do
      # The catalog is cached for an hour, so a network withdrawn inside that
      # hour answers 200 with error.code unknown_network. Measured 2026-09-14.
      handle = sqd(%{"portal_get_network_info" => fixture("sqd_unknown_network.sse")})

      assert {:error, {:unsupported_chain, "solana-mainnet"}} = Backend.call(handle, :chain_info)
    end

    test "a refusal about our own arguments is final rather than a chain fact" do
      # error.code invalid_request is the windowless account query, measured
      # 2026-09-14. A sibling source would answer the same way, so the router
      # must not walk on: {:upstream_refused, :unknown} is not a source error.
      payload = %{
        "error" => %{
          "code" => "invalid_request",
          "origin" => "client_input",
          "summary" => "Provide timeframe, from_block, or from_timestamp/to_timestamp"
        }
      }

      handle = sqd(%{"portal_get_network_info" => sse_error(payload)})

      assert {:error, {:upstream_refused, :unknown}} = Backend.call(handle, :chain_info)
    end

    test "a refusal in a plain result is read, not handed back as a body" do
      # This endpoint can announce a refusal with isError, and it can announce
      # one as a plain result whose payload IS the error object.
      # `Raxol.Web3.Backend.Tron` reads both arms off the same endpoint, and
      # reading one arm here meant a keyless read came back as a successful
      # body: the operator was told the archive returned garbage rather than
      # that this deployment holds no credential.
      handle = sqd(%{"portal_get_network_info" => sse(%{"error" => %{"code" => "unauthorized"}})})

      assert {:error, {:upstream_refused, :auth}} = Backend.call(handle, :chain_info)
    end
  end

  describe "block_height/1" do
    test "the archive asks both heads, and the lag between them is the indexer's" do
      # The recorded pair was taken back to back on 2026-09-14: latest
      # 446,956,167 against finalized 446,956,136, a lag of 31 slots, which is
      # the same figure portal_get_network_info reports as
      # finalized_lag_blocks. The lag is computed from these two numbers rather
      # than from a third call for it.
      handle =
        sqd(%{
          "portal_get_head:latest" => fixture("sqd_head_latest.sse"),
          "portal_get_head:finalized" => fixture("sqd_head_finalized.sse")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.height == 446_956_167
      assert height.finalized_height == 446_956_136
      assert height.finalized_height < height.height
      assert height.indexer.finished? == true
      assert height.indexer.lag_blocks == 31

      # SQD publishes no indexing ratio, and the key is absent rather than a
      # computed 1.0, which would be a fabricated number in the one field that
      # exists so lag is visible.
      refute Map.has_key?(height.indexer, :indexed_ratio)

      assert ["portal_list_networks", "portal_get_head:latest", "portal_get_head:finalized"] =
               requested_tools()
    end

    test "an inversion between two calls is clamped, because it is not a chain fact" do
      # The two heads are two requests, not one snapshot, so finalized can come
      # back above latest. A negative lag would be a lie about the chain; zero
      # is the truth about the pair.
      handle =
        sqd(%{
          "portal_get_head:latest" => sse(%{"number" => 100}),
          "portal_get_head:finalized" => sse(%{"number" => 140})
        })

      assert {:ok, %{indexer: %{lag_blocks: 0}}} = Backend.call(handle, :block_height)
    end

    test "the node reports slots too, and has no indexer to report" do
      handle =
        rpc(%{
          "getSlot:processed" => fixture("rpc_slot_processed.json"),
          "getSlot:finalized" => fixture("rpc_slot_finalized.json")
        })

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :slot
      assert height.height == 446_951_790
      assert height.finalized_height == 446_951_756
      assert height.finalized_height < height.height
      # A validator is not an indexer. Inventing a ratio would put a fabricated
      # number in the field that exists so lag is visible.
      assert height.indexer == nil
    end
  end

  describe "chain_info/1" do
    test "the archive reports a count of indexed blocks, not a height" do
      handle = sqd(%{"portal_get_network_info" => fixture("sqd_network_info.sse")})

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == @mainnet
      # head 446,951,619 from start_block 0.
      assert info.total_blocks == 446_951_620
      assert info.average_block_time_ms == nil
      refute Map.has_key?(info, :height)
    end

    test "the node's block count and its slot count are different numbers" do
      # The measurement the height shape exists for: 2026-09-14, one
      # getEpochInfo response carried absoluteSlot 446,951,753 and blockHeight
      # 424,994,262, a gap of 21,957,491. A caller that read the slot as a
      # block height would be wrong by twenty-two million.
      handle =
        rpc(%{
          "getEpochInfo" => fixture("rpc_epoch_info.json"),
          "getSlot:processed" => fixture("rpc_slot_processed.json"),
          "getSlot:finalized" => fixture("rpc_slot_finalized.json")
        })

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert {:ok, height} = Backend.call(handle, :block_height)

      assert info.total_blocks == 424_994_262
      assert info.total_transactions == 548_325_347_180
      assert height.height - info.total_blocks > 21_000_000
      assert height.unit == :slot
    end
  end

  describe "get_transaction/2" do
    test "carries the fee payer, the fee and the status, and invents no counterparty" do
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction.json")})

      assert {:ok, transaction} = Backend.call(handle, :get_transaction, [@signature])
      assert transaction.hash == @signature
      assert transaction.status == :success
      assert transaction.block == 446_951_766
      assert transaction.fee == 125_300
      assert transaction.from == @wallet
      assert %DateTime{} = transaction.timestamp

      # No single recipient, no single value, no single method: a transaction
      # here is instructions over a list of account keys.
      assert transaction.to == nil
      assert transaction.value == nil
      assert transaction.method == nil
    end

    test "a signature the node does not know is a refusal, not an empty transaction" do
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction_absent.json")})

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :get_transaction, [@signature])
    end

    test "a signature that is not base58 is refused before any request" do
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction.json")})

      assert {:error, {:unsupported_account_ref, :not_base58}} =
               Backend.call(handle, :get_transaction, ["0xdeadbeef" <> String.duplicate("0", 60)])

      assert [] == requested_tools()
    end

    test "an operator's own header survives the RPC POST, beside the content type" do
      # `:http_opts` is documented as forwarded unchanged, and this path
      # replaced the header list rather than merging into it, so a deployment
      # pointing this handle at its own gated node lost the credential it
      # carries in a header. `Raxol.Web3.Backend.CantonTest` asserts the same
      # property on the other backend that composes a header.
      operator = {"x-node-authorization", "operator-value"}
      handle = rpc(%{"getTransaction" => fixture("rpc_transaction.json")}, headers: [operator])

      assert {:ok, _transaction} = Backend.call(handle, :get_transaction, [@signature])

      assert [request] = drain()
      assert operator in request.headers
      assert {"content-type", "application/json"} in request.headers
    end
  end

  describe "account_info/2 and the four kinds" do
    defp account_handle(account_fixture) do
      rpc(%{"getAccountInfo" => fixture(account_fixture)})
    end

    test "a wallet says so, and carries its lamports" do
      handle = account_handle("rpc_account_info_wallet.json")

      assert {:ok, account} = Backend.call(handle, :account_info, [@wallet])
      assert account.ref == @wallet
      assert account.kind == :wallet
      assert account.contract? == false
      assert account.balance == 38_298_783_833
      assert account.verified? == false
      assert account.name == nil
    end

    test "a token account says so, and its balance is a rent reserve" do
      # The case that earned `kind` a place in the shared shape. 2,039,280
      # lamports is true and badly misleading: this account's actual holding is
      # reachable only through token_balances/2.
      handle = account_handle("rpc_account_info_token_account.json")

      assert {:ok, account} = Backend.call(handle, :account_info, [@token_account])
      assert account.kind == :token_account
      assert account.balance == 2_039_280
      assert account.contract? == false
    end

    test "a program is executable, and contract? answers code presence" do
      handle = account_handle("rpc_account_info_program.json")

      assert {:ok, account} = Backend.call(handle, :account_info, [@program])
      assert account.kind == :program
      assert account.contract? == true
    end

    test "a mint is not a token account, even though one program owns both" do
      handle = account_handle("rpc_account_info_mint.json")

      assert {:ok, %{kind: :mint}} = Backend.call(handle, :account_info, [@mint])
    end

    test "a program-owned account this table cannot name is :data, not a guess" do
      handle = account_handle("rpc_account_info_data.json")

      assert {:ok, %{kind: :data}} = Backend.call(handle, :account_info, [@sysvar])
    end

    test "an account that does not exist is a refusal, not a zero balance" do
      # On this chain an account holding nothing does not exist. Reporting zero
      # would answer a question about an account that is not there.
      handle = account_handle("rpc_account_info_absent.json")

      assert {:error, {:upstream_refused, :not_found}} =
               Backend.call(handle, :account_info, [@wallet])
    end
  end

  describe "token_balances/3" do
    test "maps the parsed token accounts, and mints no cursor it cannot honour" do
      handle = rpc(%{"getTokenAccountsByOwner" => fixture("rpc_token_accounts.json")})

      assert {:ok, page} = Backend.call(handle, :token_balances, [@wallet, []])
      assert length(page.items) == 2

      # getTokenAccountsByOwner's config object takes commitment,
      # minContextSlot, dataSlice and encoding and nothing that offsets,
      # limits or resumes, so the page is always complete and a cursor would
      # be a promise we cannot keep.
      assert page.next == nil

      assert [%{token: token, amount: amount} | _rest] = page.items
      assert token.address == "NkfbyG7feH9aJhdnSs4d7D7kWCEnxrmNUbM7dbpC6MM"
      assert token.type == "spl-token"
      assert token.decimals == 0
      assert amount == 85_000_221
      # A validator serves no token registry, so these are absent rather than
      # guessed from a mint address.
      assert token.symbol == nil
      assert token.name == nil
    end

    test "a cursor cannot have come from here, so one handed back is refused" do
      # The callback takes the option, and what the option lets it say is that
      # `next` is always nil. The nearest thing a caller could hold is this
      # same handle's signatures cursor, and answering the first page of token
      # accounts to it would answer a different question, silently. So it is
      # refused, before any request.
      handle = rpc(%{"getSignaturesForAddress" => fixture("rpc_signatures.json")})

      assert {:ok, %{next: cursor}} = Backend.call(handle, :list_transactions, [@wallet, []])
      assert is_binary(cursor)
      _signatures = drain()

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Backend.call(handle, :token_balances, [@wallet, [cursor: cursor]])

      assert [] == requested_tools()
    end
  end
end

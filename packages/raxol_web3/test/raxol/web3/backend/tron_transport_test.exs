defmodule Raxol.Web3.Backend.TronTransportTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.TronHarness

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Tron
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Router
  alias Raxol.Web3.Scope
  alias Raxol.Web3.Tables

  # A Binance cold wallet, in both encodings, and they are the same account:
  # `Raxol.Web3.Tron.Address.to_hex/1` of the first is the second.
  @base58 "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @hex "41e28b3cfd4e0e909077821478e9fcb86b84be786e"

  describe "pagination" do
    test "the node source pages on a fingerprint the caller never sees" do
      handle =
        stateful(:trongrid, %{"getAccountTransactions" => "trongrid_account_transactions.sse"})

      assert {:ok, page} = Tron.list_transactions(state(handle), {:tron, @base58})
      assert is_binary(page.next)

      fingerprint =
        fixture("trongrid_account_transactions.sse")
        |> payload()
        |> Jason.decode!()
        |> get_in(["result", "content", Access.at(0), "text"])
        |> Jason.decode!()
        |> get_in(["meta", "fingerprint"])

      refute String.contains?(page.next, fingerprint)

      assert {:ok, _second} =
               Tron.list_transactions(state(handle), {:tron, @base58}, cursor: page.next)

      assert [{_tool, first_args}, {_tool2, second_args}] = calls()
      refute Map.has_key?(first_args, "fingerprint")
      assert second_args["fingerprint"] == fingerprint
    end

    test "the explorer source pages on an offset the caller never sees" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      assert {:ok, page} = Tron.list_token_transfers(state(handle), {:tron, @base58})
      assert is_binary(page.next)
      refute String.contains?(page.next, "start")

      assert {:ok, _second} = paged_transfers(handle, page.next)

      assert [{_tool, first_args}, {_tool2, second_args}] = calls()
      assert first_args["start"] == 0
      assert second_args["start"] == 25
      assert second_args["limit"] == 25
    end

    test "a token balance walk hands its own cursor back" do
      # `token_balances/3` grew `list_opts` on 2026-09-14, so the cursor this
      # read mints is one a caller can present. It was minted and unusable
      # before that, which is the same class of dishonesty as an empty page.
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_account_tokens.sse"})

      assert {:ok, first} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      # The fixture reports 92 rows against a page of 25, so there is a next.
      assert is_binary(first.next)

      assert {:ok, _second} =
               Tron.token_balances(state(handle), {:tron, @base58}, cursor: first.next)

      assert [{_tool, %{"start" => 0, "limit" => 25}}, {_tool2, %{"start" => 25}}] = calls()
    end

    test "a read that mints no cursor refuses one" do
      # The node source answers token balances from one account record, so it
      # has no page two. Answering page one again for a cursor it never minted
      # would be indistinguishable from a walk that ended. `:wrong_scope` is
      # the reason for it, the same one the Solana backend mints for the same
      # case, and it is a `Raxol.Web3.Cursor.reason/0` variant rather than an
      # endpoint atom naming an endpoint no cursor is scoped to.
      handle = stateful(:trongrid, %{"getAccountInfo" => "trongrid_account_info.sse"})
      held = offset_cursor(handle, 25)

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Tron.token_balances(state(handle), {:tron, @base58}, cursor: held)

      assert calls() == []
    end

    test "a cursor minted through one MCP client is refused through another" do
      # A stateful source's credential lives in its client, so two clients on
      # one URL are two tenants: neither walks the other's cursor.
      routes = %{"getTransferList" => "tronscan_transfer_list.sse"}
      first = stateful(:tronscan, routes)
      second = stateful(:tronscan, routes)

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               paged_transfers(second, offset_cursor(first, 25))

      assert {:ok, _page} = paged_transfers(first, offset_cursor(first, 25))
    end

    test "a cursor minted for one endpoint is refused on another" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      wrong_scope =
        Cursor.encode(
          %{"start" => 25, "limit" => 25},
          scope(handle),
          :tronscan_account_tokens
        )

      assert {:error, {:invalid_cursor, :wrong_scope}} = paged_transfers(handle, wrong_scope)
      assert calls() == []
    end

    test "a walk that would cross the offset ceiling fails without asking" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      # 9975 + 25 is exactly the ceiling and is allowed; 9990 + 25 is not.
      assert {:ok, _page} = paged_transfers(handle, offset_cursor(handle, 9975))
      assert [{_tool, %{"start" => 9975}}] = calls()

      assert {:error, {:upstream_refused, :unknown}} =
               paged_transfers(handle, offset_cursor(handle, 9990))

      # And nothing was asked. Spending the upstream's budget on a request its
      # own documented rule refuses is the half of "fail honestly" a return
      # value cannot show.
      assert calls() == []
    end

    test "the recorded upstream refusal maps to the same error as the local check" do
      # So the local arithmetic and the upstream agree rather than diverging
      # silently the day the ceiling moves.
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_ceiling_refused.sse"})

      assert {:error, {:upstream_refused, :unknown}} =
               Tron.token_balances(state(handle), {:tron, @base58}, [])
    end

    test "the last page mints no cursor" do
      handle = stateful(:tronscan, %{"getTransferList" => "tronscan_transfer_list.sse"})

      # The fixture reports 1,860 rows, so a walk standing at 1,850 is the end.
      assert {:ok, page} = paged_transfers(handle, offset_cursor(handle, 1850))
      assert page.next == nil
    end

    test "every endpoint this backend pages has an allowlist entry" do
      # An endpoint absent from the table cannot mint or accept a cursor at all,
      # so a typo in a name would silently disable paging rather than fail.
      for endpoint <- [
            :tron_account_transactions,
            :tron_account_trc20_transfers,
            :tronscan_account_tokens,
            :tronscan_transfer_list
          ] do
        assert endpoint in Cursor.endpoints()
      end
    end
  end

  # Both offset-paged reads on this source share the `start`/`limit` pair and
  # the same 10,000 ceiling, so the ceiling and scope cases are driven through
  # the transfer list and the balance walk has its own test above.
  defp paged_transfers(handle, cursor) do
    Tron.list_token_transfers(state(handle), {:tron, @base58}, cursor: cursor)
  end

  defp offset_cursor(handle, start) do
    Cursor.encode(%{"start" => start, "limit" => 25}, scope(handle), :tronscan_transfer_list)
  end

  # A stateful source's scope is its URL and its MCP client, as `Tron` builds it.
  defp scope(handle) do
    state = state(handle)
    Scope.id(Tron.sources()[state.source].url, [{"x-raxol-mcp-client", inspect(state.client)}])
  end

  describe "errors carry no upstream text" do
    test "the archive's nested error object is classified by its code, not its prose" do
      # SQD announces a refusal as `error.code` beside a human summary, and the
      # code is a value rather than words, so it is the half this module reads.
      # The recorded body is the measurement behind declaring no optional
      # callback on this source at all: asked for an account's transactions
      # with no window, it answers 200 carrying `invalid_request` and "Provide
      # timeframe, from_block, or from_timestamp/to_timestamp to define the
      # query window", and `Backend.list_opts()` has nowhere to put one.
      handle = sqd(%{"portal_get_network_info" => "sqd_no_window.sse"})

      assert {:error, {:upstream_refused, :unknown} = reason} =
               Tron.block_height(state(handle))

      refute inspect(reason) =~ "timeframe"
      refute inspect(reason) =~ "invalid_request"
    end

    test "a refusal announced inside a successful tool result is classified" do
      handle = stateful(:trongrid, %{"getBlock" => "trongrid_missing_argument.sse"})

      assert {:error, {:upstream_refused, :unknown} = reason} =
               Tron.block_height(state(handle))

      # The recorded frame's text is "Error: Missing required argument: blockNum".
      refute inspect(reason) =~ "blockNum"
      refute inspect(reason) =~ "Missing"
    end

    test "an HTTP status from the client becomes a status and nothing else" do
      handle = stateful(:trongrid, %{"getBlock" => {:status, 500}})

      assert {:error, {:http, 500}} = Tron.block_height(state(handle))
    end

    test "a transport reason from the client lands in the closed taxonomy" do
      handle = stateful(:trongrid, %{"getBlock" => {:error, {:timeout, :chunk}}})

      assert {:error, {:timeout, :chunk}} = Tron.block_height(state(handle))
    end

    test "the ceiling refusal body names no upstream words" do
      handle = stateful(:tronscan, %{"getAccountTokens" => "tronscan_ceiling_refused.sse"})

      assert {:error, reason} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      refute inspect(reason) =~ "start + limit"
      refute inspect(reason) =~ "10000"
    end

    test "the archive's unknown_network is a chain this source does not serve, not a refusal" do
      # The same portal, the same recorded refusal shape, and until now two
      # different readings of it: `Raxol.Web3.Backend.Solana` mapped
      # `unknown_network` to `{:unsupported_chain, _}` and failed over, while
      # this module classified SQD's codes only on the arm that has no
      # `isError`, so every recorded refusal from this source -- all of which
      # carry `isError: true` -- became `{:upstream_refused, :unknown}` and
      # was final. A Tron read then died on the archive with TronGrid and
      # TronScan both healthy.
      handle =
        sqd(%{"portal_get_network_info" => {:body, sqd_fixture("sqd_unknown_network.sse")}})

      assert {:error, {:unsupported_chain, "tron-mainnet"} = reason} =
               Tron.block_height(state(handle))

      refute inspect(reason) =~ "nonexistent"
      refute inspect(reason) =~ "portal_list_networks"

      # And the router does what the classification is for.
      router = Router.new([handle, stateful(:trongrid, trongrid_height_routes())])

      assert {:ok, %{unit: :block}} = Router.call(router, "tron:0x2b6653dc", :block_height)
    end
  end

  describe "a client process that is not there" do
    test "a dead client is a transport failure the caller can act on, not an exit" do
      handle = stateful(:trongrid, trongrid_height_routes(), restart: :temporary)
      client = state(handle).client

      reference = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^reference, :process, ^client, :killed}

      # `Raxol.MCP.Client.call_tool/3` is a `GenServer.call`, and an exit is
      # not an error tuple: uncaught, this took down whatever process was
      # reading -- a router walking its candidates, or the MCP server running
      # a tool callback inline -- so the failover that exists for a dead
      # source could never run.
      assert {:error, {:transport, :client_down}} = Tron.block_height(state(handle))
    end

    test "the router fails over off a dead client to a live source" do
      dead = stateful(:trongrid, trongrid_height_routes(), restart: :temporary)
      client = state(dead).client

      reference = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^reference, :process, ^client, :killed}

      router = Router.new([dead, sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})])

      assert {:ok, %{unit: :block}} = Router.call(router, "tron:0x2b6653dc", :block_height)
    end
  end

  describe "the served surface carries no upstream name" do
    test "no tool name this backend sends upstream appears in a served definition" do
      # 149 plus 119 is 268 third-party tool descriptions for one chain, and
      # TronGrid's `tools/list` alone was 269,860 bytes on 2026-09-14. The
      # served surface is the normalized contract, so none of those names is in
      # it, nor in a description or an annotation.
      upstream = ~w(
        getBlock solidityGetBlock getBlockStatistics getAccountInfo
        getAccountTransactions getAccountTrc20Transactions getTrc20Balance
        getTransactionById getTransactionInfoById listAllAssets getTrc20Info
        getBlocks getStatsOverview getAccountDetail getAccountTokens
        getTransferList getTransactionDetail getNewestBlock
        portal_get_network_info portal_get_head portal_tron_query_transactions
      )

      router = Router.new([sqd(%{})])
      rendered = inspect(Tools.tool_defs(router)) <> inspect(Tools.names())

      for name <- upstream do
        refute rendered =~ name, "served surface mentions the upstream tool #{name}"
      end
    end
  end

  describe "Router.coverage/2 over the three sources" do
    setup do
      trongrid = stateful(:trongrid, trongrid_height_routes())
      tronscan = stateful(:tronscan, %{"getBlocks" => "tronscan_blocks.sse"})
      archive = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})

      {:ok, handles: [trongrid, archive, tronscan]}
    end

    test "names which source answers each callback, and the asymmetry between them",
         %{handles: handles} do
      coverage = Router.new(handles) |> Router.coverage("tron:0x2b6653dc")

      # Named rather than counted. `backend/0` is `:tron` for all three, so
      # before `backend/1` this map read `%{chain_info: [:tron, :tron, :tron],
      # get_transaction: [:tron, :tron], list_transactions: [:tron]}`: an
      # operator could see how many sources survived but not which, which is
      # the only question a coverage map is asked. Declaration order is the
      # operator's stated preference and survives into the answer.
      assert coverage.chain_info == [:trongrid, :sqd, :tronscan]
      assert coverage.block_height == [:trongrid, :sqd, :tronscan]

      # And the optional surface is asymmetric, which is the whole point of
      # declaring rather than assuming: the archive answers none of it, and the
      # explorer has no account-scoped transaction index, so the one source
      # missing from each row is now legible by name.
      assert coverage.get_transaction == [:trongrid, :tronscan]
      assert coverage.token_balances == [:trongrid, :tronscan]
      assert coverage.list_token_transfers == [:trongrid, :tronscan]
      assert coverage.account_info == [:trongrid, :tronscan]
      assert coverage.list_transactions == [:trongrid]
      assert coverage.get_block == [:trongrid]

      # Nothing on this chain reads a contract, resolves a name or passes a raw
      # request through, so those are absent rather than present and empty.
      refute Map.has_key?(coverage, :read_contract)
      refute Map.has_key?(coverage, :resolve_name)
      refute Map.has_key?(coverage, :raw_request)
      refute Map.has_key?(coverage, :get_logs)
    end

    test "candidates name which source answers each callback", %{handles: handles} do
      router = Router.new(handles)

      assert router |> Router.candidates("tron:0x2b6653dc", :block_height) |> sources() ==
               [:trongrid, :sqd, :tronscan]

      assert router |> Router.candidates("tron:0x2b6653dc", :list_transactions) |> sources() ==
               [:trongrid]

      assert router |> Router.candidates("tron:0x2b6653dc", :get_transaction) |> sources() ==
               [:trongrid, :tronscan]
    end

    test "the archive answers a height the node source failed" do
      failing = stateful(:trongrid, %{"getBlock" => {:status, 503}})
      archive = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})
      router = Router.new([failing, archive])

      assert {:ok, height} = Router.call(router, "tron:0x2b6653dc", :block_height)
      # The archive's recorded head, so the answer came from the fallback and
      # not from a second attempt at the primary.
      assert height.height == 86_236_774
      assert height.indexer.lag_blocks == 20
    end

    test "an open breaker on the primary's origin puts it behind the fallback" do
      # The way router_test.exs does it: the breaker is the router's input, and
      # `health_key/1` names the key the outbound path itself writes.
      trongrid = stateful(:trongrid, trongrid_height_routes())
      archive = sqd(%{"portal_get_network_info" => "sqd_network_info.sse"})
      key = Tron.health_key(state(trongrid))
      on_exit(fn -> CircuitBreaker.reset(Tables.breakers(), key) end)

      router = Router.new([trongrid, archive], breaker: [failure_threshold: 1])

      assert router |> Router.candidates("tron:0x2b6653dc", :block_height) |> sources() ==
               [:trongrid, :sqd]

      CircuitBreaker.record_failure(Tables.breakers(), key, failure_threshold: 1)

      assert router |> Router.candidates("tron:0x2b6653dc", :block_height) |> sources() ==
               [:sqd, :trongrid]

      coverage = Router.coverage(router, "tron:0x2b6653dc")
      # The archive is the one that survived, by name: a count of 1 here would
      # hold just as well if the wrong source had been the one to drop out.
      assert coverage.block_height == [:sqd]
      # The only healthy handle is the archive, which declares nothing, so the
      # optional surface vanishes entirely rather than shrinking.
      refute Map.has_key?(coverage, :list_transactions)
      refute Map.has_key?(coverage, :token_balances)
    end
  end

  # Through `Backend.name/1` rather than the struct field, because that is the
  # mechanism an operator reads a source's name by; reaching into `:source`
  # here would have kept passing while `coverage/2` said `:tron` three times.
  defp sources(handles), do: Enum.map(handles, &Backend.name/1)

  describe "the declared concurrency policy is enforced by the client" do
    test "a fan-out against a serialized origin issues one request at a time" do
      # Property-tested over randomized fan-out widths, because a single-call
      # test cannot see this failure: two parallel calls on one TronScan
      # session answered 500 for both, reproducibly, on 2026-08-31.
      handle =
        stateful(:tronscan, %{"getBlocks" => "tronscan_blocks.sse"}, hold_ms: 3)

      for _round <- 1..20 do
        drain()
        width = Enum.random(2..6)
        fan_out(handle, width)

        log = concurrency_log()

        assert length(log) == 2 * width,
               "expected #{width} bracketed requests, got #{inspect(log)}"

        assert_serialized(log)
      end
    end

    test "the same detector sees overlap on a pooled origin" do
      # The control. Without it, `assert_serialized/1` could be an assertion
      # that passes by never failing, and the serialized test above would prove
      # nothing.
      handle = stateful(:trongrid, trongrid_height_routes(), hold_ms: 25)

      overlapped? =
        Enum.any?(1..3, fn _attempt ->
          drain()
          fan_out(handle, 6)
          not serialized?(concurrency_log())
        end)

      assert overlapped?, "a pooled origin serialized six calls, so the detector proves nothing"
    end
  end

  # `getBlocks` and `getBlock` are one upstream call each, so one fan-out unit
  # is one request and the log is unambiguous.
  defp fan_out(handle, width) do
    state = state(handle)

    1..width
    |> Enum.map(fn _index -> Task.async(fn -> Tron.block_height(state) end) end)
    |> Enum.each(&Task.await(&1, 5_000))
  end

  # The seam sends `:called` on entry and `:returned` on exit, so the mailbox
  # order is the interleaving. Draining before refuting is what keeps this from
  # passing on an empty mailbox.
  defp concurrency_log(acc \\ []) do
    receive do
      {:called, _tool, _arguments, reference} -> concurrency_log([{:enter, reference} | acc])
      {:returned, reference} -> concurrency_log([{:exit, reference} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp assert_serialized(log) do
    assert serialized?(log), "two requests overlapped on a serialized origin: #{inspect(log)}"
  end

  defp serialized?(log) do
    Enum.reduce_while(log, 0, fn
      {:enter, _reference}, 0 -> {:cont, 1}
      {:enter, _reference}, _in_flight -> {:halt, :overlap}
      {:exit, _reference}, in_flight -> {:cont, in_flight - 1}
    end) != :overlap
  end

  describe "against a real upstream" do
    @describetag :live_web3

    test "the archive answers both halves of the height" do
      {:ok, handle} = Tron.new(:sqd)

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height > 80_000_000
      assert height.finalized_height < height.height
      assert height.indexer.finished? == true
    end

    test "the node source answers a height from the irreversible view" do
      handle = live(:trongrid)

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.height > 80_000_000
      # Generous bounds: the gap is the irreversible lag and not a constant.
      assert height.finalized_height < height.height
      assert height.height - height.finalized_height < 1_000
    end

    test "a mainnet account answers the same in both encodings" do
      handle = live(:trongrid)

      assert {:ok, base58} = Tron.account_info(state(handle), {:tron, @base58})
      assert {:ok, hex} = Tron.account_info(state(handle), {:tron, @hex})
      assert base58.ref == hex.ref
      assert base58.ref == {:tron, @base58}
    end

    test "both token standards come back from one real account" do
      handle = live(:trongrid)

      assert {:ok, page} = Tron.token_balances(state(handle), {:tron, @base58}, [])
      assert Enum.any?(page.items, &(&1.token.type == "TRC-10"))
      assert Enum.any?(page.items, &(&1.token.type == "TRC-20"))
      assert Enum.all?(page.items, &is_integer(&1.amount))
    end

    test "the explorer source answers a height and a confirmed height" do
      handle = live(:tronscan)

      assert {:ok, height} = Tron.block_height(state(handle))
      assert height.unit == :block
      assert height.finalized_height < height.height
    end

    # No `:tables` and no `:exchange`: this is the production wiring, so the
    # era probe, the session handshake and the real socket are all in play.
    defp live(source) do
      client = start_supervised!(Tron.client_spec(source))
      await_ready(client)
      {:ok, handle} = Tron.new(source, client: client, cache: false)
      handle
    end
  end
end

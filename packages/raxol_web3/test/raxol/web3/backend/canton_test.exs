defmodule Raxol.Web3.Backend.CantonTest do
  use ExUnit.Case, async: true

  import Raxol.Web3.Backend.CantonHarness

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Canton
  alias Raxol.Web3.Router
  alias Raxol.Web3.Serialize

  # A real party id, from a live `POST /v0/transactions` page on 2026-09-14, and
  # the party every recorded holdings fixture below was taken for.
  @party {:party,
          "tradefast-wallet3-1::1220674b79cae334aa788ffa394a6bd7d10e427d9f2abd418048e5be49ceb4256ca4"}

  # The DSO party, which holds no amulet: its holdings page is the recorded
  # empty-page-with-a-cursor case.
  @dso {:party, "DSO::1220b1431ef217342db44d516bb9befde802be7d8899637d290895fa58880f19accc"}

  describe "chain references" do
    test "the canonical reference is ours rather than registered, and the alias normalizes" do
      # No CAIP-2 namespace exists for Canton, so this pair is a decision this
      # backend documents rather than a registry lookup.
      assert {:ok, {Canton, %{chain_ref: "canton:global"}}} = Canton.new("canton:global")
      assert {:ok, {Canton, %{chain_ref: "canton:global"}}} = Canton.new("canton:mainnet")
      assert Canton.chain_refs() |> Enum.sort() == ["canton:global", "canton:mainnet"]
    end

    test "the scan base carries its own path prefix, so a Scan instance is a url change" do
      # `api.cantonnodes.com` serves the Splice Scan v0 surface under `/v0`; a
      # Scan instance serves it under `/api/scan/v0`.
      {:ok, {Canton, pinned}} =
        Canton.new("canton:global", scan_url: "https://scan.example/api/scan/v0/")

      assert pinned.scan_url == "https://scan.example/api/scan/v0"
    end
  end

  describe "capabilities" do
    test "get_block is not declared, because this chain has no blocks" do
      handle = handle(scan_routes())

      refute :get_block in Canton.capabilities(state(handle))
      refute Backend.supports?(handle, :get_block)
      assert {:error, {:unsupported, :get_block}} = Backend.call(handle, :get_block, [1])
    end

    test "Router.coverage reports the absence rather than the backend faking a block" do
      router = Router.new([handle(scan_routes())])
      coverage = Router.coverage(router, "canton:global")

      # The two required callbacks are always covered, and the four this handle
      # declares are there beside them.
      assert Map.has_key?(coverage, :chain_info)
      assert Map.has_key?(coverage, :block_height)
      assert coverage[:account_info] == [:canton]
      assert coverage[:token_balances] == [:canton]
      assert coverage[:get_transaction] == [:canton]
      assert coverage[:raw_request] == [:canton]

      # And absence is legible: this is the property ADR-0039 makes load-bearing.
      refute Map.has_key?(coverage, :get_block)
    end

    test "every read this chain cannot be asked is absent, not an empty page" do
      # `list_transactions/3` because no probed source lists by party;
      # `resolve_name/2` because the CNS directory answered empty for every
      # prefix probed; the rest because Canton has no EVM call, no contract at a
      # party, no logs and no NFT standard on this surface.
      handle = handle(scan_routes())

      for callback <- [
            :list_transactions,
            :list_token_transfers,
            :get_logs,
            :list_nfts,
            :read_contract,
            :contract_metadata,
            :resolve_name
          ] do
        refute Backend.supports?(handle, callback), "#{callback} is declared"
        assert {:error, {:unsupported, ^callback}} = Backend.call(handle, callback, [@party, []])
      end
    end

    test "the declared set does not change when a credential appears" do
      # `raw_request/2` is declared with and without a key, so a missing
      # credential is a named refusal rather than `{:unsupported, _}`, which
      # would claim the source cannot answer when it can, with an account.
      without = Canton.capabilities(state(handle(%{})))
      with_key = Canton.capabilities(state(handle(%{}, ccscan_key: "not-a-real-key")))

      assert without == with_key
      assert :raw_request in without
    end
  end

  describe "the required callbacks, keyless" do
    test "both answer with no credential configured, from the keyless scan host" do
      # Measured 2026-09-14: both required callbacks answer keyless.
      handle = handle(scan_routes())

      assert state(handle).ccscan_key == nil

      assert {:ok, info} = Backend.call(handle, :chain_info)
      assert info.chain_ref == "canton:global"

      assert {:ok, height} = Backend.call(handle, :block_height)
      assert height.unit == :round

      requests = drain()
      assert requests != []

      # No credential travelled, on any of them, in any header.
      for request <- requests do
        names = Enum.map(request.headers, fn {name, _value} -> String.downcase(name) end)
        refute "authorization" in names
      end

      # And every one of them went to the scan host rather than to ccscan.
      assert Enum.all?(requests, &String.starts_with?(&1.path, "/v0/"))
    end

    test "chain_info reports the round cadence and no counts it cannot have" do
      handle = handle(scan_routes())

      assert {:ok, info} = Backend.call(handle, :chain_info)

      # `tickDuration` is 600,000,000 microseconds in the recorded DSO body.
      assert info.average_block_time_ms == 600_000

      # Not gaps: there are no blocks to count, no addresses to count, and the
      # keyless surface publishes no chain-wide transaction total.
      assert info.total_blocks == nil
      assert info.total_addresses == nil
      assert info.total_transactions == nil
    end

    test "block_height counts rounds, and says so" do
      handle = handle(scan_routes())

      assert {:ok, height} = Backend.call(handle, :block_height)

      assert height.unit == :round
      assert height.height == 113_141

      # The same number, deliberately: Canton commits through BFT consensus with
      # no fork choice, so a round whose data is complete cannot be
      # reorganized and a consumer's confirmation depth is 0.
      assert height.finalized_height == height.height

      # `finished?` is the endpoint's own claim; the lag is the age of the
      # `effectiveAt` it carries. No ratio is published and there are no blocks
      # to lag by, so neither key is invented.
      assert height.indexer.finished? == true
      assert is_integer(height.indexer.lag_seconds)
      assert height.indexer.lag_seconds >= 0
      refute Map.has_key?(height.indexer, :indexed_ratio)
      refute Map.has_key?(height.indexer, :lag_blocks)
    end

    test "a height is asked every time, whatever the cache is doing" do
      handle = handle(scan_routes(), cache: true, scan_url: "https://cache-a.example/v0")

      assert {:ok, _first} = Backend.call(handle, :block_height)
      assert {:ok, _second} = Backend.call(handle, :block_height)

      assert Enum.count(requested_paths(), &String.ends_with?(&1, "/round-of-latest-data")) == 2
    end

    test "a round the response does not carry is a decode failure, not a zero" do
      handle = handle(%{"/v0/round-of-latest-data" => ~s({"effectiveAt":"2026-09-14T00:00:00Z"})})

      assert {:error, {:decode_failed, :round}} = Backend.call(handle, :block_height)
    end
  end

  describe "account_info/2, over a party id" do
    test "answers for a real party, with the balance in the smallest unit" do
      handle = handle(scan_routes())

      assert {:ok, account} = Backend.call(handle, :account_info, [@party])

      assert account.ref == @party

      # 1844175.4850303696 Canton Coin at ten decimal places. The upstream's
      # own gross total, not a figure netted of the accrued holding fee.
      assert account.balance == 18_441_754_850_303_696

      # The party id's own name component, self-asserted and not unique.
      assert account.name == "tradefast-wallet3-1"

      # A party holds no code and there is nothing to verify.
      assert account.contract? == false
      assert account.verified? == false
      assert account.ens == nil
    end

    test "kind is omitted rather than nil, because Canton has no account kinds" do
      # Absent means the question does not apply on this chain, which is a
      # different fact from `nil` meaning unknown.
      handle = handle(scan_routes())

      assert {:ok, account} = Backend.call(handle, :account_info, [@party])
      refute Map.has_key?(account, :kind)
    end

    test "a party with no summary row reports nil, never zero" do
      # The two are indistinguishable in the response, and no gate may read a
      # non-answer as an empty wallet.
      routes =
        Map.put(
          scan_routes(),
          "/v0/holdings/summary",
          ~s({"record_time":"2026-09-14T00:00:00Z","migration_id":4,"summaries":[]})
        )

      assert {:ok, account} = Backend.call(handle(routes), :account_info, [@dso])
      assert account.balance == nil
    end

    test "the party travels in a POST body, so its colons need no escaping" do
      handle = handle(scan_routes())

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      summary = Enum.find(drain(), &(&1.path == "/v0/holdings/summary"))
      assert summary.method == "POST"
      assert %{"owner_party_ids" => [party]} = Jason.decode!(summary.body)
      assert party == elem(@party, 1)
      assert party =~ "::"
    end

    test "an operator's own header survives the POST reads, beside the content type" do
      # `:http_opts` is documented as forwarded unchanged, and the POST path
      # replaced the header list rather than merging into it. The GET reads
      # kept the operator's headers and these two dropped them, so an
      # RBAC-gated Scan instance answered 403 on the party-scoped reads alone
      # while every other read on the same host worked.
      operator = {"x-scan-authorization", "operator-value"}
      handle = handle(scan_routes(), headers: [operator])

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      requests = drain()
      summary = Enum.find(requests, &(&1.path == "/v0/holdings/summary"))
      dso = Enum.find(requests, &(&1.path == "/v0/dso"))

      assert operator in summary.headers
      assert {"content-type", "application/json"} in summary.headers
      # The GET reads never lost it, which is what made the gap invisible.
      assert operator in dso.headers
    end

    test "the snapshot is resolved from the derived migration id, not a hardcoded one" do
      # Measured 2026-09-14: every `migrationId` published in `/v0/dso` is "4",
      # nested per super-validator inside a Daml-encoded map.
      handle = handle(scan_routes())

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      snapshot = Enum.find(drain(), &String.starts_with?(&1.path, "/v0/state/acs/"))
      assert snapshot.path =~ "migration_id=4"
    end

    test "a pinned migration id skips the derivation rather than overriding it after the fact" do
      handle = handle(scan_routes(), migration_id: 0)

      assert {:ok, _account} = Backend.call(handle, :account_info, [@party])

      paths = requested_paths()
      assert Enum.any?(paths, &(&1 =~ "migration_id=0"))
      refute Enum.any?(paths, &(&1 == "/v0/dso"))
    end

    test "a migration id nowhere in the DSO body is a decode failure, not a default" do
      routes = Map.put(scan_routes(), "/v0/dso", ~s({"dso_party_id":"DSO::1220ab"}))

      assert {:error, {:decode_failed, :migration_id}} =
               Backend.call(handle(routes), :account_info, [@party])
    end
  end

  describe "the party tag, across the served surface" do
    test "a party reference round-trips as party:Alice::1220abcd" do
      # The parse splits on the FIRST colon only, which is what makes a party
      # id's own `::` survive. This is the backend half of what
      # `Raxol.Web3.MCP.ToolsTest` asserts on the surface side.
      assert Serialize.account_ref("party:Alice::1220abcd") == {:party, "Alice::1220abcd"}
      assert Serialize.result({:party, "Alice::1220abcd"}) == "party:Alice::1220abcd"
    end

    test "a reference parsed from the surface comes back out of the backend unchanged" do
      handle = handle(scan_routes())
      incoming = "party:" <> elem(@party, 1)

      assert {:ok, account} =
               Backend.call(handle, :account_info, [Serialize.account_ref(incoming)])

      assert Serialize.result(account.ref) == incoming
    end
  end
end

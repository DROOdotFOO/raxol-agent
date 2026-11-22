defmodule Raxol.Web3.Backend.ConformanceTest do
  @moduledoc false
  # Properties every backend owes the contract, checked over all of them at
  # once: a refused chain names itself, every declared capability is
  # implemented, a foreign account reference is refused by its tag before any
  # request, and a credential-bearing URL never renders in `inspect/1`.
  use ExUnit.Case, async: true

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Aztec
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Backend.Canton
  alias Raxol.Web3.Backend.JSONRPC
  alias Raxol.Web3.Backend.Solana
  alias Raxol.Web3.Backend.Tron

  @secret "key-not-real-7f3a"

  # Callbacks whose first argument is an account reference.
  @account_callbacks [
    :account_info,
    :token_balances,
    :list_transactions,
    :list_token_transfers,
    :list_nfts,
    :contract_metadata,
    :get_logs
  ]

  # Any request reaching the wire is recorded and refused, so a property that
  # must hold "before any request" can say so.
  defp http_opts do
    test = self()

    [
      exchange: fn _vetted, request, _opts ->
        send(test, {:request, request.path})
        {:ok, %{status: 599, headers: [], body: ""}}
      end,
      resolver: fn
        _host, :inet -> {:ok, [{93, 184, 216, 34}]}
        _host, :inet6 -> {:ok, []}
      end,
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      headers: [{"authorization", "Bearer " <> @secret}]
    ]
  end

  # The account-reference tag each handle answers for; every other tag is foreign.
  @own_tag %{
    blockscout: :evm,
    jsonrpc: :evm,
    aztec: :aztec,
    solana_sqd: :solana,
    solana_rpc: :solana,
    canton: :party,
    tron_sqd: :tron,
    tron_trongrid: :tron,
    tron_tronscan: :tron
  }

  @tags [:evm, :aztec, :solana, :party, :tron, :conformance]

  # The handle fields that carry an operator's credential. Tron takes no
  # operator URL; its credential, if any, is a header in `http_opts`.
  @credential_fields %{
    blockscout: [:rpc_url],
    jsonrpc: [:url],
    aztec: [:base_url],
    solana_sqd: [:url],
    solana_rpc: [:url],
    canton: [:scan_url, :ccscan_url, :ccscan_key]
  }

  # One handle per backend and source, with @secret in every operator URL (in
  # the path, and in the query string for Solana's RPC), in an authorization
  # header, and in the ccscan key.
  defp handles do
    url = "https://node.conformance.example/v2/#{@secret}"
    query_url = "https://node.conformance.example/?api-key=#{@secret}"
    opts = [http_opts: http_opts(), cache: false]

    [
      blockscout: Blockscout.new("eip155:1", [rpc_url: url] ++ opts),
      jsonrpc: JSONRPC.new("eip155:1", [url: url] ++ opts),
      aztec: Aztec.new("aztec:mainnet", [base_url: url] ++ opts),
      solana_sqd: Solana.new("solana:mainnet", [source: :sqd, url: url] ++ opts),
      solana_rpc: Solana.new("solana:mainnet", [source: :rpc, url: query_url] ++ opts),
      canton:
        Canton.new(
          "canton:global",
          [scan_url: url, ccscan_url: url <> "/mcp", ccscan_key: @secret] ++ opts
        ),
      tron_sqd: Tron.new(:sqd, opts),
      tron_trongrid: Tron.new(:trongrid, [client: :conformance_no_client] ++ opts),
      tron_tronscan: Tron.new(:tronscan, [client: :conformance_no_client] ++ opts)
    ]
    |> Enum.map(fn {name, {:ok, handle}} -> {name, handle} end)
  end

  test "a chain reference a backend does not serve is refused by name" do
    # A foreign namespace and a near miss inside the backend's own namespace.
    refusals = [
      {&Blockscout.new/1, ["solana:mainnet", "eip155:999999"]},
      {&Aztec.new/1, ["eip155:1", "aztec:testnet"]},
      {&Solana.new/1, ["eip155:1", "solana:devnet"]},
      {&Canton.new/1, ["eip155:1", "canton:devnet"]},
      {&Tron.new(:sqd, chain_ref: &1), ["eip155:1", "tron:shasta"]}
    ]

    for {new, refs} <- refusals, ref <- refs do
      assert {:error, {:unsupported_chain, ^ref}} = new.(ref)
    end
  end

  test "every declared capability and every required callback is implemented" do
    for {name, {module, state} = handle} <- handles() do
      for {callback, _arity} <- Backend.required() do
        assert function_exported?(module, callback, 1), "#{name} lacks #{callback}"
      end

      for callback <- module.capabilities(state) do
        assert Backend.supports?(handle, callback),
               "#{name} declares #{callback} without implementing it"
      end
    end
  end

  test "a foreign account reference is refused by its tag, before any request" do
    checked =
      for {name, {module, state} = handle} <- handles(),
          callback <- module.capabilities(state),
          callback in @account_callbacks do
        for tag <- @tags -- [@own_tag[name]] do
          assert {:error, {:unsupported_account_ref, ^tag}} =
                   Backend.call(handle, callback, [{tag, "x"}]),
                 "#{name}.#{callback} did not refuse #{tag}"
        end

        assert {:error, {:unsupported_account_ref, :unknown}} =
                 Backend.call(handle, callback, ["untagged"]),
               "#{name}.#{callback} did not refuse an untagged reference"

        {name, callback}
      end

    # Every backend and source with an account callback contributes, so none
    # can silently drop out. The two SQD archives declare no optional callback.
    assert checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Map.keys(@own_tag) -- [:solana_sqd, :tron_sqd])

    assert length(checked) >= 15
    refute_received {:request, _path}
  end

  # Ids that are, or decode into, a dot segment, or an empty one. Each would
  # resolve off its endpoint on a server or proxy that normalizes paths.
  @dot_ids [
    ".",
    "..",
    "",
    "%2e",
    "%2E%2e",
    ".%2e",
    "%252e%252e",
    "..%2Fadmin",
    "x/../y",
    "..\\x",
    "%2e%2e%5cx",
    "..;",
    "..;/x",
    "...",
    ". ",
    "..%00",
    "%u002e%u002e"
  ]

  test "an id that is or decodes into a dot segment is refused before any request" do
    calls = [
      blockscout: [get_transaction: & &1, get_block: & &1],
      aztec: [get_transaction: & &1, get_block: & &1, contract_metadata: &{:aztec, &1}],
      canton: [get_transaction: & &1]
    ]

    handles = Map.new(handles())

    for {name, callbacks} <- calls, {callback, wrap} <- callbacks, id <- @dot_ids do
      assert {:error, {:invalid_argument, _field}} =
               Backend.call(handles[name], callback, [wrap.(id)]),
             "#{name}.#{callback} sent #{inspect(id)}"
    end

    refute_received {:request, _path}
  end

  test "a credential never renders when a handle is inspected, and is still held" do
    for {name, {_module, state} = handle} <- handles() do
      refute inspect(handle, limit: :infinity) =~ @secret, "#{name} renders a credential"

      # Redaction is of the rendering, not the state: an authenticated node
      # still gets its key, in the field that carries it.
      for field <- Map.get(@credential_fields, name, []) do
        assert Map.fetch!(state, field) =~ @secret, "#{name} dropped its credential from #{field}"
      end
    end
  end
end

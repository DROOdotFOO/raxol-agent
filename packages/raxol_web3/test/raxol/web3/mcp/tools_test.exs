defmodule Raxol.Web3.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Registry
  alias Raxol.MCP.Server
  alias Raxol.MCP.ToolDef
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.MCP.Error
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Router
  alias Raxol.Web3.Serialize

  @chain "eip155:1"
  @address "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
  @hash "0x" <> String.duplicate("ab", 32)

  defp router(opts \\ []) do
    {:ok, handle} = Stub.new(@chain, opts)
    Router.new([handle])
  end

  defp tool(router, name) do
    Enum.find(Tools.tool_defs(router), &(&1.name == name))
  end

  # A result is JSON text, decoded here so a test reads it as a client does.
  # An error is a `Raxol.Web3.MCP.Error`, which matches `%{code:, detail:}`.
  defp call(router, name, arguments) do
    case raw_call(router, name, arguments) do
      {:ok, json} when is_binary(json) -> {:ok, Jason.decode!(json)}
      other -> other
    end
  end

  defp raw_call(router, name, arguments), do: tool(router, name).callback.(arguments)

  defp registry do
    name = :"web3_tools_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name, table_name: name})
    name
  end

  describe "the registered surface is read-only and authorization-gated" do
    test "no tool takes a method name, because raw_request has no tool at all" do
      # The contract's one passthrough callback is absent from the surface, so
      # there is no served path that can name an RPC method.
      refute :raw_request in Tools.callbacks()
      refute Enum.any?(Tools.names(), &String.contains?(&1, "raw"))

      assert Enum.all?(Tools.tool_defs(router()), fn tool ->
               not String.contains?(Jason.encode!(tool.inputSchema), "method")
             end)
    end

    test "every account argument names every family Serialize reads" do
      descriptions =
        for %{inputSchema: %{"properties" => %{"account" => %{"description" => d}}}} <-
              Tools.tool_defs(router()),
            do: d

      assert length(descriptions) == 7

      for description <- descriptions, tag <- Serialize.tags(), tag != "evm" do
        assert description =~ ~s("#{tag}:), tag
      end
    end

    test "every registered tool is one this package declared" do
      # ADR-0033 section 4's check, and the one the MCP server does not perform:
      # enumerate the registry after registration and fail on anything else.
      registry = registry()

      assert :ok = Tools.register(registry, router())

      registered = registry |> Registry.list_tools() |> Enum.map(& &1.name) |> Enum.sort()

      assert registered == Enum.sort(Tools.names())
    end

    test "every registered tool is sensitive as well as read-only" do
      # Reads still disclose query intent and can consume provider quota, so
      # the MCP server must refuse an unguarded deployment.
      for tool <- Tools.tool_defs(router()) do
        assert ToolDef.sensitive?(tool), "#{tool.name} is not authorization-gated"
        assert tool.annotations == %{readOnlyHint: true, sensitive: true}
      end
    end

    test "an MCP server refuses this surface without an authorizer" do
      registry = registry()
      assert :ok = Tools.register(registry, router())
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Server.start_link(
                 name: :"web3_unguarded_#{System.unique_integer([:positive])}",
                 registry: registry
               )

      assert message =~ "refuses to boot"
      assert message =~ "web3_"
    end

    test "every tool passes the registry's own shape validation" do
      for tool <- Tools.tool_defs(router()) do
        assert :ok = ToolDef.validate(tool), "#{tool.name} is not a valid tool_def"
      end
    end

    test "the tool list and the callback list are the same length, in the same order" do
      # Both are derived from one table, and this is what catches a hand-edit
      # that adds a name without a callback or the reverse.
      assert length(Tools.names()) == length(Tools.callbacks())
      assert length(Tools.names()) == 13
    end

    test "an answer about the question does not open the tool's breaker" do
      # `Raxol.MCP.Registry` opens a per-tool breaker after five `{:error, _}`
      # results, and five is one probe short of a working day's worth of empty
      # wallets. An unfunded account is `{:upstream_refused, :not_found}`,
      # which is the answer the caller asked for, and quarantining
      # `web3_account_info` for it took the tool out on every chain at once.
      registry = registry()
      router = router(answers: %{account_info: {:error, {:upstream_refused, :not_found}}})

      assert :ok = Tools.register(registry, router)

      for _probe <- 1..6 do
        assert {:error, %{code: "upstream_refused", detail: :not_found}} =
                 Registry.call_tool(registry, "web3_account_info", %{
                   "chain" => @chain,
                   "account" => @address
                 })
      end

      assert Registry.circuit_status(registry, {:tool, "web3_account_info"}).state == :closed
    end

    test "a fault of the source does open it, so the classification is a split and not a mute" do
      registry = registry()
      router = router(answers: %{account_info: {:error, {:timeout, :deadline}}})

      assert :ok = Tools.register(registry, router)

      for _attempt <- 1..5 do
        assert {:error, %{code: "timeout"}} =
                 Registry.call_tool(registry, "web3_account_info", %{
                   "chain" => @chain,
                   "account" => @address
                 })
      end

      assert {:error, :circuit_open} =
               Registry.call_tool(registry, "web3_account_info", %{
                 "chain" => @chain,
                 "account" => @address
               })
    end

    test "a 404 an upstream never classified is an answer, not a fault" do
      # A backend that cannot classify a status hands it through as
      # `{:http, status}`, and Blockscout answers an unknown hash with a
      # plain 404: five lookups of hashes that do not exist, from one client,
      # took `web3_get_transaction` out for every client of the server.
      registry = registry()
      router = router(answers: %{get_transaction: {:error, {:http, 404}}})
      arguments = %{"chain" => @chain, "hash" => @hash}

      assert :ok = Tools.register(registry, router)

      for _probe <- 1..6 do
        assert {:error, %{code: "http", detail: 404}} =
                 Registry.call_tool(registry, "web3_get_transaction", arguments)
      end

      assert Registry.circuit_status(registry, {:tool, "web3_get_transaction"}).state == :closed
    end

    test "a 5xx from the same upstream still is a fault" do
      # The other side of the split, so that classifying `{:http, _}` as an
      # answer wholesale fails here. The line is
      # `Raxol.Web3.HTTP.unhealthy_status?/1`, the one the origin breaker and
      # the router's failover already use.
      registry = registry()
      router = router(answers: %{get_transaction: {:error, {:http, 503}}})
      arguments = %{"chain" => @chain, "hash" => @hash}

      assert :ok = Tools.register(registry, router)

      for _attempt <- 1..5 do
        assert {:error, %{code: "http", detail: 503}} =
                 Registry.call_tool(registry, "web3_get_transaction", arguments)
      end

      assert {:error, :circuit_open} =
               Registry.call_tool(registry, "web3_get_transaction", arguments)
    end
  end

  describe "arguments" do
    test "a chain is required on every tool" do
      for tool <- Tools.tool_defs(router()) do
        assert "chain" in tool.inputSchema["required"]
        assert tool.inputSchema["properties"]["chain"]["type"] == "string"
      end
    end

    test "a missing required argument is refused without reaching a backend" do
      router = router(answers: %{chain_info: {:error, :should_not_be_called}})

      assert {:error, %{code: "missing_argument", detail: "chain"}} =
               call(router, "web3_chain_info", %{})

      assert {:error, %{code: "missing_argument", detail: "hash"}} =
               call(router, "web3_get_transaction", %{"chain" => @chain})
    end

    test "no tool raises on an absent argument, whatever interned its name" do
      # The lookup was `Map.get(arguments, name) ||
      # Map.get(arguments, String.to_existing_atom(name))`, so EVERY absent
      # argument evaluated `String.to_existing_atom/1`. No `:chain` literal
      # exists in `raxol_web3/lib`, so the test above passed only because
      # `%{chain: @chain}` below interned that atom while this file compiled;
      # in a release the tool raised `ArgumentError` instead of naming the
      # missing argument. The names now come from a compile-time table in the
      # module itself, and this covers every one of them.
      router = router()
      refused = {"missing_argument", "chain"}

      answered =
        Map.new(Tools.names(), fn name ->
          {:error, %Error{code: code, detail: detail}} = call(router, name, %{})
          {name, {code, detail}}
        end)

      assert answered == Map.new(Tools.names(), &{&1, refused})
    end

    test "atom keys and string keys both work" do
      # JSON arrives with string keys; a local Elixir caller writes atoms.
      # Guessing wrong reports a supplied argument as missing.
      router = router()

      assert {:ok, _} = call(router, "web3_chain_info", %{"chain" => @chain})
      assert {:ok, _} = call(router, "web3_chain_info", %{chain: @chain})
    end

    test "a bare address becomes an EVM account reference" do
      router = router()

      assert {:ok, account} =
               call(router, "web3_account_info", %{"chain" => @chain, "account" => @address})

      assert account["ref"] == "evm:#{@address}"
    end

    test "an explicitly tagged reference keeps its tag" do
      # The tag is what distinguishes a Tron account from an EVM one and a
      # Canton party from either. A surface that flattened it would have to
      # guess on the way back in.
      router = router()

      assert {:ok, account} =
               call(router, "web3_account_info", %{
                 "chain" => @chain,
                 "account" => "party:Alice::1220abcd"
               })

      assert account["ref"] == "party:Alice::1220abcd"
    end

    test "an optional cursor is passed through and an absent one is not invented" do
      router = router(answers: %{list_transactions: {:ok, %{items: [], next: "opaque"}}})

      assert {:ok, %{"next" => "opaque"}} =
               call(router, "web3_list_transactions", %{"chain" => @chain, "account" => @address})

      assert {:ok, %{"next" => "opaque"}} =
               call(router, "web3_list_transactions", %{
                 "chain" => @chain,
                 "account" => @address,
                 "cursor" => "somecursor"
               })
    end

    test "an argument of the wrong type is a closed error rather than a raise" do
      # Neither `Raxol.MCP.Server` nor `Raxol.MCP.Registry` enforces
      # `inputSchema`, so an argument's type is whatever the peer sent.
      # Unchecked, `{"account": 123}` reached `Serialize.account_ref/1`,
      # which is guarded `when is_binary(value)`: the `FunctionClauseError`
      # was rendered into the result a model reads AND counted against the
      # tool's breaker, so five wrong-typed calls disabled the tool for every
      # client.
      router = router()

      wrong = [
        {"web3_account_info", %{"chain" => @chain, "account" => 123}, "account"},
        {"web3_contract_metadata", %{"chain" => @chain, "account" => %{}}, "account"},
        {"web3_get_transaction", %{"chain" => @chain, "hash" => 42}, "hash"},
        {"web3_resolve_name", %{"chain" => @chain, "name" => ["vitalik.eth"]}, "name"},
        {"web3_read_contract", %{"chain" => @chain, "to" => "0xabc", "data" => %{}}, "data"},
        {"web3_read_contract",
         %{"chain" => @chain, "to" => "0xabc", "data" => "0x70a08231", "block" => 3.5}, "block"},
        {"web3_list_transactions", %{"chain" => @chain, "account" => @address, "cursor" => 7},
         "cursor"},
        {"web3_chain_info", %{"chain" => 1}, "chain"},
        {"web3_get_block", %{"chain" => @chain, "number" => 1.5}, "number"},
        {"web3_get_block", %{"chain" => @chain, "number" => %{"n" => 1}}, "number"}
      ]

      for {name, arguments, detail} <- wrong do
        assert {:error, %{code: "invalid_argument", detail: ^detail}} =
                 call(router, name, arguments),
               "#{name} did not refuse #{inspect(arguments)}"
      end
    end

    test "a wrong-typed argument is not evidence against the tool" do
      # The other half: a closed refusal that still counted as a fault would
      # let a model disable a working tool by sending the wrong JSON type
      # five times.
      registry = registry()
      assert :ok = Tools.register(registry, router())

      for _attempt <- 1..6 do
        assert {:error, %{code: "invalid_argument", detail: "account"}} =
                 Registry.call_tool(registry, "web3_account_info", %{
                   "chain" => @chain,
                   "account" => 123
                 })
      end

      assert {:ok, _account} =
               Registry.call_tool(registry, "web3_account_info", %{
                 "chain" => @chain,
                 "account" => @address
               })
    end
  end

  describe "results are JSON, not Elixir terms" do
    test "a whole page encodes, tagged references and timestamps included" do
      # The defect ADR-0033 section 4 rejects AgentBridge for: a result
      # rendered with inspect/2 is Elixir term syntax that a client decoding
      # JSON receives as a string, if at all.
      router = router()

      assert {:ok, json} =
               raw_call(router, "web3_list_transactions", %{
                 "chain" => @chain,
                 "account" => @address
               })

      assert is_binary(json)
      assert {:ok, decoded} = Jason.decode(json)

      assert [item] = decoded["items"]
      assert item["from"] == "evm:#{@address}"
      assert item["status"] == "success"
      assert item["timestamp"] =~ "2026-"
    end

    test "every tool answers JSON text that decodes to an object" do
      router = router()

      for {name, arguments} <- every_call() do
        assert {:ok, json} = raw_call(router, name, arguments), "#{name} did not answer"
        assert is_binary(json), "#{name} answered a term, not text"
        assert {:ok, %{} = _object} = Jason.decode(json), "#{name} is not a JSON object"
      end
    end

    test "the two scalar answers are wrapped in an object" do
      router = router()

      assert {:ok, %{"account" => "evm:" <> _address}} =
               call(router, "web3_resolve_name", %{"chain" => @chain, "name" => "vitalik.eth"})

      assert {:ok, %{"value" => "0x" <> _word}} =
               call(router, "web3_read_contract", %{
                 "chain" => @chain,
                 "to" => @address,
                 "data" => "0x70a08231"
               })
    end

    test "a result that is not an object is a closed error, not a non-object answer" do
      unreadable = [
        {:account_info, nil, "web3_account_info", %{"account" => @address}},
        {:account_info, [], "web3_account_info", %{"account" => @address}},
        {:account_info, ~U[2026-11-28 12:00:00Z], "web3_account_info", %{"account" => @address}},
        {:chain_info, "text", "web3_chain_info", %{}},
        {:resolve_name, {:unknown, "0xabc"}, "web3_resolve_name", %{"name" => "vitalik.eth"}},
        {:resolve_name, {:evm, 42}, "web3_resolve_name", %{"name" => "vitalik.eth"}},
        {:resolve_name, "0xabc", "web3_resolve_name", %{"name" => "vitalik.eth"}},
        {:read_contract, nil, "web3_read_contract", %{"to" => @address, "data" => "0x"}}
      ]

      for {callback, answer, name, arguments} <- unreadable do
        router = router(answers: %{callback => {:ok, answer}})

        assert {:error, %Error{code: "decode_failed", detail: :result}} =
                 call(router, name, Map.put(arguments, "chain", @chain)),
               "#{callback} answering #{inspect(answer)}"
      end
    end

    test "an unreadable result counts against the tool, as a source fault" do
      router = router(answers: %{account_info: {:ok, nil}})

      assert {:error, error} =
               call(router, "web3_account_info", %{"chain" => @chain, "account" => @address})

      assert Tools.fault?(error)
    end

    test "a wei balance past 2^53 arrives as its exact decimal string" do
      # 5_799_554_154_377_317_710 is the balance Blockscout reported for the
      # address above on 2026-11-28. As a JSON number a double reads it as
      # 5799554154377317376.
      balance = 5_799_554_154_377_317_710
      answer = {:ok, %{ref: {:evm, @address}, balance: balance, contract?: false}}
      router = router(answers: %{account_info: answer})

      assert {:ok, account} =
               call(router, "web3_account_info", %{"chain" => @chain, "account" => @address})

      assert account["balance"] == "5799554154377317710"
      assert String.to_integer(account["balance"]) == balance
      assert account["contract?"] == false
    end
  end

  describe "errors" do
    test "an error is a code, its own datum and a fixed hint, with no upstream text" do
      # The hint is chosen from the code and datum, so no upstream byte can
      # reach it, which is the property ADR-0038 decision 6 spends its rules
      # on. This surface is where a leak would be worst: a tool result is text
      # a model reads and may act on.
      router = router(answers: %{chain_info: {:error, {:rate_limited, 500}}})

      assert {:error, error} = call(router, "web3_chain_info", %{"chain" => @chain})

      assert Error.to_map(error) == %{
               "code" => "rate_limited",
               "detail" => 500,
               "hint" => "The source is rate limiting this client. Retry after 500 ms."
             }
    end

    test "an unrouted chain names the chains that are routed" do
      {:ok, ethereum} = Stub.new(@chain)
      {:ok, tron} = Stub.new("tron:0x2b6653dc")
      router = Router.new([tron, ethereum])

      assert {:error, error} = call(router, "web3_chain_info", %{"chain" => "eip155:8453"})
      assert %{code: "no_backend", chains: ["eip155:1", "tron:0x2b6653dc"]} = error

      assert %{"chains" => ["eip155:1", "tron:0x2b6653dc"], "hint" => hint} =
               Error.to_map(error)

      assert hint =~ "\"chains\""
    end

    test "a router with no chains does not offer an empty list to pick from" do
      assert {:error, error} = call(Router.new([]), "web3_chain_info", %{"chain" => @chain})

      assert %{"code" => "no_backend", "chains" => [], "hint" => hint} = Error.to_map(error)
      assert hint =~ "serves no chains"
      refute hint =~ "\"chains\""
    end

    test "an error built without the router's chains claims neither" do
      hint = Error.new(:no_backend).hint

      assert hint == "No backend serves this chain."
    end

    test "only no_backend carries the chains key" do
      router = router(answers: %{chain_info: {:error, {:timeout, :deadline}}})

      assert {:error, error} = call(router, "web3_chain_info", %{"chain" => @chain})
      assert error |> Error.to_map() |> Map.keys() |> Enum.sort() == ~w(code detail hint)
    end

    test "a name where an account belongs says to call web3_resolve_name first" do
      # The account is not resolved on the caller's behalf: one call stays one
      # read, and the address a read is about is one the caller has seen. The
      # real Blockscout handle decides an address locally, so no request is
      # made here.
      {:ok, blockscout} = Raxol.Web3.Backend.Blockscout.new(@chain)
      router = Router.new([blockscout])

      for tool <- ~w(web3_account_info web3_token_balances web3_list_transactions),
          account <- ["vitalik.eth", "evm:vitalik.eth"] do
        assert {:error, error} =
                 call(router, tool, %{"chain" => @chain, "account" => account})

        assert %{code: "unsupported_account_ref", detail: :not_an_address} = error
        assert error.hint =~ "web3_resolve_name", "#{tool} #{account}"
      end
    end

    test "a name behind evm: is told to drop the prefix; a bare name's hint is unchanged" do
      hint = fn account ->
        Error.new({:unsupported_account_ref, :not_an_address}, %{account: account}).hint
      end

      assert hint.("vitalik.eth") ==
               "This looks like a name. Call web3_resolve_name with it and the same chain, " <>
                 "then pass the account it returns."

      assert hint.("evm:vitalik.eth") ==
               ~s(This looks like a name. Drop the "evm:" prefix and call web3_resolve_name ) <>
                 "with the name alone and the same chain, then pass the account it returns."
    end

    test "a dotted value behind another family's prefix is not taken for a name" do
      context = %{account: "tron:vitalik.eth"}
      hint = Error.new({:unsupported_account_ref, :not_an_address}, context).hint

      refute hint =~ "web3_resolve_name"
    end

    test "an address of the wrong form gets the family hint, not the name hint" do
      {:ok, blockscout} = Raxol.Web3.Backend.Blockscout.new(@chain)
      router = Router.new([blockscout])

      assert {:error, error} =
               call(router, "web3_account_info", %{"chain" => @chain, "account" => "0x1234"})

      assert error.code == "unsupported_account_ref"
      refute error.hint =~ "web3_resolve_name"
      assert error.hint =~ "solana:"
    end

    test "a malformed EVM transaction hash is refused before any backend is asked" do
      router = router(answers: %{get_transaction: {:error, {:http, 422}}})

      for hash <- ["0x1234", "1234", "0x" <> String.duplicate("zz", 32), @hash <> "00"] do
        assert {:error, error} =
                 call(router, "web3_get_transaction", %{"chain" => @chain, "hash" => hash})

        assert %{code: "invalid_argument", detail: "hash"} = error
        assert error.hint =~ "64 hex characters"
      end
    end

    test "a well-formed hash in either case reaches the backend" do
      router = router()
      upper = "0x" <> String.duplicate("AB", 32)

      for hash <- [@hash, upper] do
        assert {:ok, %{"hash" => _hash}} =
                 call(router, "web3_get_transaction", %{"chain" => @chain, "hash" => hash})
      end
    end

    test "the hash check is EVM-only: other families keep deciding their own ids" do
      # A Tron transaction id has no 0x prefix and would fail the EVM check.
      tron = "tron:0x2b6653dc"
      {:ok, handle} = Stub.new(tron)

      assert {:ok, _transaction} =
               call(Router.new([handle]), "web3_get_transaction", %{
                 "chain" => tron,
                 "hash" => String.duplicate("ab", 32)
               })
    end

    test "a timeout says the source timed out and that a retry or less may work" do
      router = router(answers: %{token_balances: {:error, {:timeout, :chunk}}})

      assert {:error, error} =
               call(router, "web3_token_balances", %{"chain" => @chain, "account" => @address})

      assert %{code: "timeout", detail: :chunk} = error
      assert error.hint =~ "timed out (stage: chunk)"
      assert error.hint =~ "A retry may work."
      assert error.hint =~ "ask for less"
    end

    test "a callback no backend answers is reported as unsupported" do
      router = router(capabilities: [])

      assert {:error, %{code: "unsupported", detail: :get_logs}} =
               call(router, "web3_get_logs", %{"chain" => @chain, "account" => @address})
    end

    test "a nested datum from a backend is an answered error, not a raised callback" do
      registry = registry()
      router = router(answers: %{chain_info: {:error, {:timeout, {:chunk, 30_000}}}})
      assert :ok = Tools.register(registry, router)

      assert {:error, %Error{code: "timeout"}} =
               Registry.call_tool(registry, "web3_chain_info", %{"chain" => @chain})
    end

    test "an unrecognised error term becomes a bare code rather than being inspected" do
      router = router(answers: %{chain_info: {:error, {:weird, %{body: "upstream text"}}}})

      assert {:error, error} = call(router, "web3_chain_info", %{"chain" => @chain})
      assert Error.to_map(error) == %{"code" => "error", "detail" => nil, "hint" => nil}
      refute inspect(error) =~ "upstream text"
    end
  end

  defp every_call do
    [
      {"web3_chain_info", %{"chain" => @chain}},
      {"web3_block_height", %{"chain" => @chain}},
      {"web3_get_transaction", %{"chain" => @chain, "hash" => @hash}},
      {"web3_account_info", %{"chain" => @chain, "account" => @address}},
      {"web3_list_transactions", %{"chain" => @chain, "account" => @address}},
      {"web3_token_balances", %{"chain" => @chain, "account" => @address}},
      {"web3_list_token_transfers", %{"chain" => @chain, "account" => @address}},
      {"web3_get_logs", %{"chain" => @chain, "account" => @address}},
      {"web3_list_nfts", %{"chain" => @chain, "account" => @address}},
      {"web3_contract_metadata", %{"chain" => @chain, "account" => @address}},
      {"web3_get_block", %{"chain" => @chain, "number" => 1_000_000}},
      {"web3_resolve_name", %{"chain" => @chain, "name" => "vitalik.eth"}},
      {"web3_read_contract", %{"chain" => @chain, "to" => "0xabc", "data" => "0x70a08231"}}
    ]
  end
end

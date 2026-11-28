defmodule Raxol.Web3.MCP.RoutingTest do
  # Serial: one test opens the breaker of a real Blockscout origin, which is
  # shared by host, so no async sibling may run beside it.
  use ExUnit.Case, async: false

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.MCP.Error
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @chain "eip155:1"
  @address "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  defp call(router, name, arguments) do
    tool = Enum.find(Tools.tool_defs(router), &(&1.name == name))

    case tool.callback.(arguments) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      other -> other
    end
  end

  test "page two while the minter's breaker is open: the client hears the pause, not a bad cursor" do
    {:ok, minter} = Blockscout.new(@chain, cache: false, http_opts: paging_exchange())

    {:ok, other} =
      Stub.new(@chain,
        name: :other,
        cursor_scopes: ["another-source"],
        answers: %{list_transactions: {:error, {:invalid_cursor, :wrong_scope}}}
      )

    router = Router.new([minter, other])
    arguments = %{"chain" => @chain, "account" => @address}

    assert {:ok, %{"next" => cursor}} = call(router, "web3_list_transactions", arguments)
    assert is_binary(cursor)

    key = Backend.health_key(minter)
    on_exit(fn -> CircuitBreaker.reset(Tables.breakers(), key) end)
    CircuitBreaker.record_failure(Tables.breakers(), key, failure_threshold: 1)

    assert {:error, %Error{code: "breaker_open"} = error} =
             call(router, "web3_list_transactions", Map.put(arguments, "cursor", cursor))

    assert error.hint == "The source failed repeatedly and is paused. Retry later."
    assert Tools.fault?(error)

    CircuitBreaker.reset(Tables.breakers(), key)

    assert {:ok, %{"items" => [%{"hash" => "0xpage2"}]}} =
             call(router, "web3_list_transactions", Map.put(arguments, "cursor", cursor))
  end

  test "a chain whose first source is misconfigured: the fallback answers every read" do
    {:ok, broken} =
      Stub.new(@chain,
        name: :"broken_#{System.unique_integer([:positive])}",
        answers: %{
          chain_info: {:error, {:blocked, :invalid_url}},
          account_info: {:error, {:blocked, :invalid_url}}
        }
      )

    {:ok, fallback} = Stub.new(@chain, name: :fallback)
    router = Router.new([broken, fallback])

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{"average_block_time_ms" => _}} =
               call(router, "web3_chain_info", %{"chain" => @chain})

      assert {:ok, %{"balance" => _}} =
               call(router, "web3_account_info", %{"chain" => @chain, "account" => @address})
    end)
  end

  defp paging_exchange do
    [
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end,
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      exchange: fn _vetted, request, _opts ->
        body =
          if String.contains?(request.path, "block_number=") do
            ~s({"items":[{"hash":"0xpage2"}],"next_page_params":null})
          else
            ~s({"items":[{"hash":"0xpage1"}],"next_page_params":{"block_number":1,"index":2,"items_count":50}})
          end

        {:ok, %{status: 200, headers: [], body: body}}
      end
    ]
  end
end

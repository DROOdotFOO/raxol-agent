defmodule Raxol.Web3.MCP.ServerTest do
  # The text a client receives, through the real `Raxol.MCP.Server`.
  use ExUnit.Case, async: true

  alias Raxol.MCP.Protocol
  alias Raxol.MCP.Registry
  alias Raxol.MCP.Server
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Router

  @chain "eip155:1"
  @address "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  setup do
    name = :"web3_json_#{System.unique_integer([:positive])}"
    registry = :"#{name}_registry"
    start_supervised!({Registry, name: registry, table_name: registry})

    balance = 5_799_554_154_377_317_710

    {:ok, stub} =
      Stub.new(@chain,
        answers: %{
          account_info: {:ok, %{ref: {:evm, @address}, balance: balance, contract?: false}}
        }
      )

    :ok = Tools.register(registry, Router.new([stub]))

    server =
      start_supervised!(
        {Server,
         name: name,
         registry: registry,
         authorizer_source: :configured,
         authorizer: fn _name, _arguments, _context -> :allow end}
      )

    {:ok, server: server}
  end

  defp call_tool(server, name, arguments) do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    {:ok, message} = Protocol.decode(request)
    {:reply, response} = Server.handle_message(server, message)
    %{content: [%{type: "text", text: text}]} = result = response.result
    {Map.get(result, :isError, false), text}
  end

  test "a result is JSON text a client decodes, with the balance exact", %{server: server} do
    assert {false, text} =
             call_tool(server, "web3_account_info", %{"chain" => @chain, "account" => @address})

    assert %{"balance" => "5799554154377317710", "ref" => "evm:" <> _} = Jason.decode!(text)
  end

  test "an error is JSON after the server's fixed prefix", %{server: server} do
    assert {true, "Error: " <> json} =
             call_tool(server, "web3_chain_info", %{"chain" => "eip155:8453"})

    assert %{"code" => "no_backend", "chains" => [@chain], "hint" => _hint} =
             Jason.decode!(json)
  end
end

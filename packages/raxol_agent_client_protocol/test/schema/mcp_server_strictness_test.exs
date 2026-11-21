# MCP server descriptors feed a spawned command line or an HTTP client, so their
# fields must have the right types or the request fails decode (-32602).
defmodule Raxol.AgentClientProtocol.Schema.McpServerStrictnessTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{McpServer, NewSessionRequest}

  @stdio %{"name" => "s", "command" => "/bin/srv", "args" => ["--x"], "env" => []}
  @http %{"type" => "http", "name" => "h", "url" => "https://x", "headers" => []}

  test "well-typed descriptors decode" do
    assert {:ok, {:stdio, _}} = McpServer.from_json(@stdio)
    assert {:ok, {:http, _}} = McpServer.from_json(@http)
    assert {:ok, {:sse, _}} = McpServer.from_json(%{@http | "type" => "sse"})
  end

  test "stdio command, name and args must be strings" do
    for {key, bad} <- [
          {"command", ["sh", "-c", "x"]},
          {"name", 1},
          {"args", "--x"},
          {"args", ["a", 1]}
        ] do
      assert {:error, {:invalid_field, ^key, ^bad}} =
               McpServer.from_json(Map.put(@stdio, key, bad))
    end
  end

  test "env and header names and values must be strings" do
    assert {:error, {:invalid_field, "value", 1}} =
             McpServer.from_json(%{@stdio | "env" => [%{"name" => "K", "value" => 1}]})

    assert {:error, {:invalid_field, "name", nil}} =
             McpServer.from_json(%{@http | "headers" => [%{"name" => nil, "value" => "v"}]})
  end

  test "http and sse url must be a string" do
    assert {:error, {:invalid_field, "url", %{}}} = McpServer.from_json(%{@http | "url" => %{}})
  end

  test "a bad descriptor fails the whole session/new request" do
    assert {:error, {:invalid_field, "command", 1}} =
             NewSessionRequest.from_json(%{
               "cwd" => "/w",
               "mcpServers" => [%{@stdio | "command" => 1}]
             })
  end

  test "an unknown type is refused instead of decoding as a spawned process" do
    assert {:error, {:invalid_mcp_server_type, "HTTP"}} =
             McpServer.from_json(Map.put(@stdio, "type", "HTTP"))

    assert {:ok, {:stdio, _}} = McpServer.from_json(Map.put(@stdio, "type", "stdio"))
  end
end

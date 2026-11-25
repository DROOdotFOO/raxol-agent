# Ported from the MIT `f1729/agent_client_protocol` test suite (c) 2025 f1729; see NOTICE.md.
# Byte-level wire fixtures; `from_json/1` assertions use the total contract.
defmodule Raxol.AgentClientProtocol.Schema.SerializationTest do
  use ExUnit.Case, async: true
  @moduledoc "Cross-cutting JSON serialization tests matching the upstream Rust test cases."

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerStdio

  test "McpServer stdio serialization matches Rust" do
    server =
      {:stdio,
       %McpServerStdio{
         name: "test-server",
         command: "/usr/bin/server",
         args: ["--port", "3000"],
         env: [EnvVariable.new("API_KEY", "secret123")]
       }}

    json = McpServer.to_json(server)

    assert json == %{
             "name" => "test-server",
             "command" => "/usr/bin/server",
             "args" => ["--port", "3000"],
             "env" => [%{"name" => "API_KEY", "value" => "secret123"}]
           }

    {:ok, decoded} = McpServer.from_json(json)
    assert {:stdio, stdio} = decoded
    assert stdio.name == "test-server"
    assert stdio.command == "/usr/bin/server"
    assert stdio.args == ["--port", "3000"]
    assert length(stdio.env) == 1
    assert hd(stdio.env).name == "API_KEY"
  end

  test "McpServer http serialization matches Rust" do
    server =
      {:http,
       %McpServerHttp{
         name: "http-server",
         url: "https://api.example.com",
         headers: [
           HttpHeader.new("Authorization", "Bearer token123"),
           HttpHeader.new("Content-Type", "application/json")
         ]
       }}

    json = McpServer.to_json(server)
    assert json["type"] == "http"
    assert json["name"] == "http-server"
    assert json["url"] == "https://api.example.com"
    assert length(json["headers"]) == 2

    {:ok, decoded} = McpServer.from_json(json)
    assert {:http, http} = decoded
    assert http.name == "http-server"
    assert length(http.headers) == 2
  end

  test "McpServer sse serialization matches Rust" do
    server =
      {:sse,
       %McpServerSse{
         name: "sse-server",
         url: "https://sse.example.com/events",
         headers: [HttpHeader.new("X-API-Key", "apikey456")]
       }}

    json = McpServer.to_json(server)
    assert json["type"] == "sse"
    assert json["name"] == "sse-server"

    {:ok, decoded} = McpServer.from_json(json)
    assert {:sse, sse} = decoded
    assert sse.url == "https://sse.example.com/events"
  end

  test "full initialize round-trip" do
    req = InitializeRequest.new(1)
    json = InitializeRequest.to_json(req)
    encoded = Jason.encode!(json)
    decoded_json = Jason.decode!(encoded)
    {:ok, decoded} = InitializeRequest.from_json(decoded_json)
    assert decoded.protocol_version == 1
  end

  test "notification wire format" do
    notif = CancelNotification.new("test-123")
    json = CancelNotification.to_json(notif)
    assert json == %{"sessionId" => "test-123"}
  end

  test "nil fields omitted from JSON" do
    impl = Implementation.new("test", "1.0")
    json = Implementation.to_json(impl)
    refute Map.has_key?(json, "title")
    refute Map.has_key?(json, "_meta")
  end

  test "meta field uses _meta key" do
    impl = %Implementation{name: "test", version: "1.0", _meta: %{"custom" => true}}
    json = Implementation.to_json(impl)

    # Matches upstream: ACP.Implementation.to_json/1 nests the meta bucket
    # under the wire "_meta" key.
    assert json["_meta"] == %{"custom" => true}
    refute Map.has_key?(json, "custom")

    {:ok, decoded} = Implementation.from_json(json)
    assert decoded._meta == %{"custom" => true}
  end
end

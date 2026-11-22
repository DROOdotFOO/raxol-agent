defmodule Raxol.Earn.Transport.SSEStreamTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.{Auth, Transport}
  alias Raxol.Earn.ProviderAdapter.JSONRPC
  alias Raxol.Earn.Transport.SSE
  alias Raxol.Earn.Transport.SSE.Parser

  # Anvil's first dev account: a public test key.
  @key Base.decode16!("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
         case: :lower
       )

  describe "Parser.feed/2" do
    test "carries an unterminated frame across chunks" do
      assert {[], tail} = Parser.feed("", ~s|data: {"a":|)
      assert {[%{"a" => 1}], ""} = Parser.feed(tail, ~s|1}\n\n|)
    end

    test "parses several frames from one chunk and keeps the remainder" do
      assert {[%{"a" => 1}, %{"b" => 2}], ~s|data: {"c"|} =
               Parser.feed("", ~s|data: {"a":1}\n\ndata: {"b":2}\n\ndata: {"c"|)
    end

    test "drops frames without data or with invalid JSON" do
      assert {[%{"ok" => true}], ""} =
               Parser.feed("", ~s|event: ping\n\ndata: nope\n\ndata: {"ok":true}\n\n|)
    end
  end

  describe "connect/2 stream" do
    test "delivers an entry split across chunks to the owner" do
      chunks = [
        ~s|data: {"kind":"mess|,
        ~s|age","n":1}\n\ndata: {"kind":"message",|,
        ~s|"n":2}\n\n|
      ]

      plug = &serve(&1, chunks)

      provider = JSONRPC.new(chains: %{8453 => "http://127.0.0.1:1"}, private_key: @key)

      {:ok, auth} =
        Auth.start_link(
          provider: provider,
          server_url: "https://acp.test",
          chain_id: 8453,
          req_options: [plug: plug, retry: false]
        )

      transport =
        SSE.new(auth: auth, server_url: "https://acp.test", req_options: [plug: plug])

      assert :ok = Transport.connect(transport, %{owner: self()})

      assert_receive {:transport, %{"kind" => "message", "n" => 1}}, 2_000
      assert_receive {:transport, %{"kind" => "message", "n" => 2}}, 2_000
      refute_receive {:transport, _}, 50

      assert :ok = Transport.disconnect(transport)
    end
  end

  defp serve(%Plug.Conn{request_path: "/auth/agent"} = conn, _chunks) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(%{"data" => %{"token" => jwt()}}))
  end

  defp serve(%Plug.Conn{request_path: "/chats/stream"} = conn, chunks) do
    Enum.reduce(chunks, Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  defp jwt do
    payload = Jason.encode!(%{"exp" => System.system_time(:second) + 3_600})

    Enum.map_join(
      [~s|{"alg":"none"}|, payload, "sig"],
      ".",
      &Base.url_encode64(&1, padding: false)
    )
  end
end

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

    test "splits CRLF-framed events" do
      assert {[%{"a" => 1}, %{"b" => 2}], ""} =
               Parser.feed("", ~s|data: {"a":1}\r\n\r\ndata: {"b":2}\r\n\r\n|)
    end

    test "joins a CRLF that straddles two chunks" do
      assert {[], tail} = Parser.feed("", ~s|data: {"a":1}\r\n\r|)
      assert {[%{"a" => 1}], ""} = Parser.feed(tail, "\n")
    end

    test "drops frames without data or with invalid JSON" do
      assert {[%{"ok" => true}], ""} =
               Parser.feed("", ~s|event: ping\n\ndata: nope\n\ndata: {"ok":true}\n\n|)
    end
  end

  describe "connect/2 stream" do
    test "delivers an entry split across chunks to the owner" do
      transport =
        connect!([
          ~s|data: {"kind":"mess|,
          ~s|age","n":1}\n\ndata: {"kind":"message",|,
          ~s|"n":2}\n\n|
        ])

      assert_receive {:transport, %{"kind" => "message", "n" => 1}}, 2_000
      assert_receive {:transport, %{"kind" => "message", "n" => 2}}, 2_000
      refute_receive {:transport, _}, 50

      assert :ok = Transport.disconnect(transport)
    end

    test "closes the stream once an unterminated event passes the limit" do
      limit = 64
      flood = "data: " <> String.duplicate("x", limit)

      transport =
        connect!([~s|data: {"n":1}\n\n|, flood, ~s|data: {"n":2}\n\n|],
          max_sse_buffer_bytes: limit
        )

      assert_receive {:transport, %{"n" => 1}}, 2_000
      assert_receive {ref, {:error, {:sse_buffer_overflow, ^limit}}} when is_reference(ref), 2_000
      refute_received {:transport, %{"n" => 2}}

      assert :ok = Transport.disconnect(transport)
    end

    test "an event within the limit still arrives when split across chunks" do
      limit = 64
      value = String.duplicate("y", limit - byte_size(~s|data: {"v":""}|))
      event = ~s|data: {"v":"#{value}"}|
      {head, tail} = String.split_at(event, div(byte_size(event), 2))

      transport = connect!([head, tail <> "\n\n"], max_sse_buffer_bytes: limit)

      assert_receive {:transport, %{"v" => ^value}}, 2_000
      assert_receive {ref, :ok} when is_reference(ref), 2_000

      assert :ok = Transport.disconnect(transport)
    end

    test "a transport failure ends the task with an error, not a clean close" do
      transport = connect!(:econnreset)

      assert_receive {ref, {:error, {:transport, :econnreset}}} when is_reference(ref), 2_000
      assert :ok = Transport.disconnect(transport)
    end
  end

  describe "new/1" do
    test "rejects a buffer limit that is not a positive integer" do
      for bad <- [0, -1, "1024", nil] do
        assert_raise ArgumentError, ~r/:max_sse_buffer_bytes must be a positive integer/, fn ->
          SSE.new(auth: self(), server_url: "https://acp.test", max_sse_buffer_bytes: bad)
        end
      end
    end
  end

  defp connect!(chunks, opts \\ []) do
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
      SSE.new([auth: auth, server_url: "https://acp.test", req_options: [plug: plug]] ++ opts)

    :ok = Transport.connect(transport, %{owner: self()})
    transport
  end

  defp serve(%Plug.Conn{request_path: "/auth/agent"} = conn, _chunks) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(%{"data" => %{"token" => jwt()}}))
  end

  defp serve(%Plug.Conn{request_path: "/chats/stream"} = conn, reason) when is_atom(reason),
    do: Req.Test.transport_error(conn, reason)

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

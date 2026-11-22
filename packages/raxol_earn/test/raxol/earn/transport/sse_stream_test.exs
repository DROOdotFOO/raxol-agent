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

  # Feeds chunks through Parser.feed/3 and collects what comes out.
  defp run(chunks, max_bytes \\ 1_048_576) do
    Enum.reduce(chunks, {[], 0, Parser.new()}, fn chunk, {entries, dropped, state} ->
      {new, d, state} = Parser.feed(state, chunk, max_bytes)
      {entries ++ new, dropped + d, state}
    end)
  end

  describe "Parser.feed/3" do
    test "carries an unterminated frame across chunks" do
      assert {[%{"a" => 1}], 0, %{tail: ""}} = run([~s|data: {"a":|, ~s|1}\n\n|])
    end

    test "parses several frames from one chunk and keeps the remainder" do
      assert {[%{"a" => 1}, %{"b" => 2}], 0, %{tail: ~s|data: {"c"|}} =
               run([~s|data: {"a":1}\n\ndata: {"b":2}\n\ndata: {"c"|])
    end

    test "splits CRLF-framed events" do
      assert {[%{"a" => 1}, %{"b" => 2}], 0, _} =
               run([~s|data: {"a":1}\r\n\r\ndata: {"b":2}\r\n\r\n|])
    end

    test "joins a CRLF that straddles two chunks" do
      assert {[%{"a" => 1}], 0, %{tail: ""}} = run([~s|data: {"a":1}\r\n\r|, "\n"])
    end

    test "splits bare-CR-framed events as soon as their boundary arrives" do
      assert {[%{"a" => 1}, %{"b" => 2}], 0, _} =
               run([~s|data: {"a":1}\r\rdata: {"b":2}\r|, "\r"])

      assert {[%{"a" => 1}], 0, _} = run([~s|data: {"a":1}\r|, ~s|\rdata: {"b"|])
    end

    test "a CR then LF across chunks is one line ending, not two" do
      assert {[], 0, %{tail: tail}} = run([~s|data: {"a":1}\r|, "\n"])
      assert tail == ~s|data: {"a":1}\n|

      assert {[%{"a" => 1}], 0, _} = run([~s|data: {"a":1}\r|, "\n", "\r\n"])
    end

    test "only the LF straight after a CR is swallowed" do
      assert {[%{"a" => 1}], 0, %{cr_pending?: false}} = run([~s|data: {"a":1}\r|, "\n", "\n"])
    end

    test "drops frames without data or with invalid JSON" do
      assert {[%{"ok" => true}], 0, _} =
               run([~s|event: ping\n\ndata: nope\n\ndata: {"ok":true}\n\n|])
    end

    test "drops an event that outgrows the limit and parses the ones after it" do
      flood = "data: " <> String.duplicate("x", 100)

      assert {[%{"n" => 1}, %{"n" => 2}], 1, %{skipping?: false}} =
               run([~s|data: {"n":1}\n\n|, flood, "xxx", "x\n", ~s|\ndata: {"n":2}\n\n|], 64)
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

    test "drops an oversized event once and keeps the stream" do
      limit = 64
      flood = "data: " <> String.duplicate("x", limit)

      test_pid = self()
      handler = "sse-dropped-#{inspect(make_ref())}"

      :telemetry.attach(
        handler,
        [:raxol, :earn, :transport, :sse_dropped],
        fn _event, measurements, meta, _ -> send(test_pid, {:dropped, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transport =
            connect!([~s|data: {"n":1}\n\n|, flood, "\n\n", ~s|data: {"n":2}\n\n|],
              max_sse_buffer_bytes: limit
            )

          assert_receive {:transport, %{"n" => 1}}, 2_000
          assert_receive {:transport, %{"n" => 2}}, 2_000
          assert_receive {ref, :ok} when is_reference(ref), 2_000
          assert :ok = Transport.disconnect(transport)
        end)

      assert [_one] = Regex.scan(~r/dropped 1 event\(s\) larger than 64 bytes/, log)
      assert_received {:dropped, %{count: 1}, %{max_bytes: 64}}
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

    test "an error status ends the task with an error and its body is not parsed" do
      transport = connect!({502, ~s|data: {"n":1}\n\n|})

      assert_receive {ref, {:error, {:http_status, 502}}} when is_reference(ref), 2_000
      refute_received {:transport, _}
      assert :ok = Transport.disconnect(transport)
    end

    test "a stream that closes at once with no entries is not counted healthy" do
      transport = connect!([": keepalive\n\n"])

      assert_receive {ref, {:error, :closed_early}} when is_reference(ref), 2_000
      assert :ok = Transport.disconnect(transport)
    end

    test "an unterminated tail exactly at the limit is still held" do
      limit = 64
      tail = "data: " <> String.duplicate("z", limit - 6)
      assert byte_size(tail) == limit

      transport = connect!([~s|data: {"n":1}\n\n|, tail], max_sse_buffer_bytes: limit)

      assert_receive {:transport, %{"n" => 1}}, 2_000
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

  defp serve(%Plug.Conn{request_path: "/chats/stream"} = conn, {status, body}),
    do: Plug.Conn.send_resp(conn, status, body)

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

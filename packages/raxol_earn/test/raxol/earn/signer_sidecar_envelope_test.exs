defmodule Raxol.Earn.SignerSidecar.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.SignerSidecar
  alias Raxol.Earn.SignerSidecar.Envelope

  @script Path.expand("../../../priv/signer_sidecar/envelope.mjs", __DIR__)
  @node System.find_executable("node")

  if is_nil(@node) do
    @moduletag skip: "node not on PATH -- the Node half of the envelope is not exercised"
  end

  # Surrounding whitespace is part of the vector: both sides trim it.
  @signer_key "  envelope-test-authorization-key\n"
  @address "0x468AEAE798B3a6548ac2401d276f83afdc172283"

  # Runs envelope.mjs on the same inputs and returns what it computed, so the
  # two implementations are checked against each other, not each against itself.
  defp node_eval(js) do
    prelude = "import * as e from #{Jason.encode!("file://" <> @script)};\n"

    {out, 0} =
      System.cmd(@node, ["--input-type=module", "-e", prelude <> js], stderr_to_stdout: true)

    Jason.decode!(out)
  end

  test "both sides derive the same key and the same request and response signatures" do
    key = Envelope.derive_key(@signer_key)
    body = ~s|{"chainId":8453,"message":"héllo"}|
    nonce = String.duplicate("0f", 16)
    ts = "1700000000000"
    req = Envelope.request_sig(key, "POST", "/sign-message", body, ts, nonce)

    node =
      node_eval("""
      const k = e.deriveKey(#{Jason.encode!(@signer_key)});
      const req = e.requestSig(k, "post", "/sign-message", #{Jason.encode!(body)}, #{Jason.encode!(ts)}, #{Jason.encode!(nonce)});
      console.log(JSON.stringify({
        key: k.toString("hex"),
        req,
        res: e.responseSig(k, req, 200, #{Jason.encode!(@address)}, #{Jason.encode!(body)})
      }));
      """)

    assert node["key"] == Base.encode16(key, case: :lower)
    assert node["req"] == req
    assert node["res"] == Envelope.response_sig(key, req, 200, @address, body)
  end

  test "the sidecar accepts a request the BEAM signed, once, and refuses tampering and staleness" do
    key = Envelope.derive_key(@signer_key)
    body = ~s|{"chainId":8453}|
    {_nonce, headers} = Envelope.request_headers(key, "POST", "/send-calls", body)
    headers = Map.new(headers)

    stale =
      Map.put(headers, "x-raxol-ts", Integer.to_string(System.system_time(:millisecond) - 60_000))

    result =
      node_eval("""
      const k = e.deriveKey(#{Jason.encode!(@signer_key)});
      const seen = new Map();
      const req = (headers, body, path = "/send-calls") => ({ method: "POST", path, headers, body });
      const h = #{Jason.encode!(headers)};
      console.log(JSON.stringify({
        first: e.verifyRequest(k, req(h, #{Jason.encode!(body)}), Date.now(), seen),
        replay: e.verifyRequest(k, req(h, #{Jason.encode!(body)}), Date.now(), seen),
        body: e.verifyRequest(k, req(h, '{"chainId":1}'), Date.now(), new Map()),
        path: e.verifyRequest(k, req(h, #{Jason.encode!(body)}, "/sign-message"), Date.now(), new Map()),
        stale: e.verifyRequest(k, req(#{Jason.encode!(stale)}, #{Jason.encode!(body)}), Date.now(), new Map()),
        missing: e.verifyRequest(k, req({}, #{Jason.encode!(body)}), Date.now(), new Map()),
        other_key: e.verifyRequest(e.deriveKey("other"), req(h, #{Jason.encode!(body)}), Date.now(), new Map())
      }));
      """)

    assert result == %{
             "first" => nil,
             "replay" => "replayed",
             "body" => "bad_signature",
             "path" => "bad_signature",
             "stale" => "stale",
             "missing" => "missing_auth",
             "other_key" => "bad_signature"
           }
  end

  test "the sidecar's loopback check matches the BEAM's" do
    hosts = [
      "127.0.0.1",
      "127.9.9.9",
      "localhost",
      "::1",
      "[::1]",
      "0.0.0.0",
      "10.0.0.5",
      "signer.example"
    ]

    node = node_eval("console.log(JSON.stringify(#{Jason.encode!(hosts)}.map(e.isLoopback)));")

    elixir =
      Enum.map(hosts, fn host ->
        try do
          SignerSidecar.check_url!("http://#{if host == "::1", do: "[::1]", else: host}:1")

          true
        rescue
          ArgumentError -> false
        end
      end)

    assert node == elixir
    assert node == [true, true, true, true, true, false, false, false]
  end
end

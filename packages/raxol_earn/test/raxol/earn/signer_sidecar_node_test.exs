defmodule Raxol.Earn.SignerSidecarNodeTest do
  # The sidecar's real request handling (priv/signer_sidecar/app.mjs) under the
  # BEAM's real client, with only the Privy SDK adapter stood in.
  use ExUnit.Case, async: true

  alias Raxol.Earn.ProviderAdapter.Privy
  alias Raxol.Earn.SignerSidecar
  alias Raxol.Earn.SignerSidecar.Envelope

  @node System.find_executable("node")
  @app Path.expand("../../../priv/signer_sidecar/app.mjs", __DIR__)
  @fake Path.expand("../../support/fake_sidecar.mjs", __DIR__)
  @signer_key "node-test-authorization-key"
  @wallet "0x468AEAE798B3a6548ac2401d276f83afdc172283"

  if is_nil(@node) do
    @moduletag skip: "node not on PATH -- the sidecar handler is not exercised"
  end

  setup do
    port =
      Port.open({:spawn_executable, @node}, [
        :binary,
        {:line, 1024},
        args: [@fake, "file://" <> @app, @signer_key, @wallet]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    receive do
      {^port, {:data, {:eol, line}}} ->
        {:ok, url: "http://127.0.0.1:#{Jason.decode!(line)["port"]}"}
    after
      5_000 -> flunk("fake sidecar did not start")
    end
  end

  defp adapter(url, key \\ Envelope.derive_key(@signer_key)),
    do: Privy.new(sidecar_url: url, address: @wallet, chains: %{8453 => url}, auth_key: key)

  test "signs, sends and passes the health check for the right key and wallet", %{url: url} do
    assert {:ok, <<_::binary-size(65)>>} = Privy.sign_message(adapter(url), 8453, "hello")
    assert {:ok, [_hash]} = Privy.send_calls(adapter(url), 8453, [%{to: "0x1", data: "0x"}])
    assert :ok = SignerSidecar.await_health(url, 2_000, @wallet, Envelope.derive_key(@signer_key))
  end

  test "a client without the key is refused, unsigned", %{url: url} do
    assert {:error, {:sidecar_refused, "bad_signature"}} =
             Privy.sign_message(adapter(url, Envelope.derive_key("wrong")), 8453, "x")

    assert {:ok, %Req.Response{status: 401} = resp} = Req.get(url <> "/health", retry: false)
    assert Req.Response.get_header(resp, "x-raxol-sig") == []
    assert resp.body["reason"] == "missing_auth"
  end

  test "a replayed or stale request is refused", %{url: url} do
    key = Envelope.derive_key(@signer_key)
    {_sig, headers} = Envelope.request_headers(key, "GET", "/health", "")
    send_it = fn h -> Req.get!(url <> "/health", headers: h, retry: false) end

    assert send_it.(headers).status == 200
    assert %{status: 401, body: %{"reason" => "replayed"}} = send_it.(headers)

    stale = Integer.to_string(System.system_time(:millisecond) - 60_000)
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    sig = Envelope.request_sig(key, "GET", "/health", "", stale, nonce)
    old = [{"x-raxol-ts", stale}, {"x-raxol-nonce", nonce}, {"x-raxol-sig", sig}]

    assert %{status: 401, body: %{"reason" => "stale"}} = send_it.(old)
  end

  test "an unknown route answers a signed 404", %{url: url} do
    key = Envelope.derive_key(@signer_key)

    assert {:ok, 404, %{"error" => "not_found"}} =
             SignerSidecar.call(url, "POST", "/nope", %{}, key, @wallet)
  end

  test "the health check sees a sidecar for another wallet as such", %{url: url} do
    other = "0x939ead944b5d28b86d91af1961812d3bbc46cac1"

    assert {:error, {:sidecar_wrong_wallet, @wallet, ^other}} =
             SignerSidecar.await_health(url, 2_000, other, Envelope.derive_key(@signer_key))
  end
end

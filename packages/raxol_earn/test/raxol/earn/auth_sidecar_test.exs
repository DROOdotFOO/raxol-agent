defmodule Raxol.Earn.AuthSidecarTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Auth
  alias Raxol.Earn.ProviderAdapter.Privy
  alias Raxol.Earn.TestSupport.TestSidecar

  @wallet "0x" <> String.duplicate("cd", 20)

  # Every token refresh signs through the sidecar, and every sidecar response
  # is authenticated, so a refresh is itself an identity check.
  test "a token refresh fails once the sidecar can no longer prove itself" do
    sig = "0x" <> String.duplicate("ab", 65)
    holder = TestSidecar.start(@wallet, %{"/sign-typed-data" => {200, %{signature: sig}}})

    provider =
      Privy.new(
        sidecar_url: "http://127.0.0.1:4048",
        address: @wallet,
        chains: %{8453 => "http://127.0.0.1:1"},
        auth_key: TestSidecar.key(),
        req_options: [plug: {TestSidecar, holder}, retry: false]
      )

    {:ok, auth} =
      Auth.start_link(
        provider: provider,
        server_url: "https://acp.test",
        chain_id: 8453,
        req_options: [plug: &token_endpoint/1, retry: false]
      )

    assert {:ok, _token} = Auth.token(auth)

    TestSidecar.set_mode(holder, :impostor)
    :ok = Auth.invalidate(auth)

    assert {:error, :sidecar_unauthenticated} = Auth.token(auth)
  end

  defp token_endpoint(conn) do
    payload = Jason.encode!(%{"exp" => System.system_time(:second) + 3_600})

    jwt =
      Enum.map_join(
        [~s|{"alg":"none"}|, payload, "sig"],
        ".",
        &Base.url_encode64(&1, padding: false)
      )

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(%{"data" => %{"token" => jwt}}))
  end
end

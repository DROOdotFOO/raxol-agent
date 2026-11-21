defmodule Raxol.Earn.AuthRedactionTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Auth
  alias Raxol.Earn.ProviderAdapter.JSONRPC

  # anvil account 0; signing only, no RPC call is made.
  @key Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")

  test "a fetched bearer JWT stays out of inspect and :sys.get_status" do
    payload = Base.url_encode64(Jason.encode!(%{"exp" => 4_102_444_800}), padding: false)
    jwt = "eyJhbGciOiJub25lIn0." <> payload <> ".sig-redaction-test"

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"data" => %{"token" => jwt}})
    end)

    provider = JSONRPC.new(chains: %{8453 => "https://rpc.test/v2/rpc-key"}, private_key: @key)

    {:ok, auth} =
      Auth.start_link(
        provider: provider,
        server_url: "https://acp.test",
        chain_id: 8453,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    Req.Test.allow(__MODULE__, self(), auth)

    assert {:ok, ^jwt} = Auth.token(auth)

    status = inspect(:sys.get_status(auth))
    refute status =~ "sig-redaction-test"
    refute status =~ "rpc-key"
    refute inspect(:sys.get_state(auth)) =~ "sig-redaction-test"
  end
end

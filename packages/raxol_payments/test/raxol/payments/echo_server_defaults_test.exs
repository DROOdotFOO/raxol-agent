defmodule Raxol.Payments.EchoServerDefaultsTest do
  # Serial: every echo server listens under the one Cowboy ref
  # `Raxol.Payments.EchoServer.HTTP`, so each test starts and stops its own.
  use ExUnit.Case, async: false

  alias Raxol.Payments.{EchoServer, Ledger, SpendingPolicy}
  alias Raxol.Payments.Protocols.X402
  alias Raxol.Payments.Req.AutoPay

  @key_env "RAXOL_ECHO_DEFAULTS_TEST_KEY"
  @base_sepolia "eip155:84532"
  @base_sepolia_usdc "0x036cbd53842c5426634e7929541ec2318f3dcf7e"

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ECHO_DEFAULTS_TEST_KEY"
  end

  setup do
    # A fresh key per test, never funded: its mainnet signatures move nothing.
    System.put_env(@key_env, "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    {:ok, ledger} =
      Ledger.start_link(table_name: :"echo_defaults_#{System.unique_integer([:positive])}")

    on_exit(fn -> System.delete_env(@key_env) end)

    %{ledger: ledger, port: 4600 + :rand.uniform(400)}
  end

  defp start_server(opts) do
    {:ok, _pid} = EchoServer.start_link(opts)
    on_exit(fn -> Plug.Cowboy.shutdown(EchoServer.HTTP) end)
  end

  defp challenge(port) do
    resp = Req.get!("http://localhost:#{port}/anything", retry: false)
    assert resp.status == 402
    [encoded] = Req.Response.get_header(resp, "payment-required")
    encoded |> Base.decode64!() |> Jason.decode!()
  end

  defp pay(port, ledger) do
    policy = %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("10.00"),
      lifetime_max: Decimal.new("100.00"),
      session_window_ms: 3_600_000,
      currency: "USDC",
      approved_domains: ["localhost"]
    }

    Req.new(url: "http://localhost:#{port}/anything", retry: false)
    |> AutoPay.attach(wallet: Wallet, ledger: ledger, policy: policy, agent_id: :echo_defaults)
    |> Req.get!()
  end

  test "a server started with defaults issues a challenge the x402 client pays",
       %{ledger: ledger, port: port} do
    start_server(port: port)

    %{"network" => network, "asset" => asset} = challenge(port)
    assert X402.signable_asset?(network, asset)

    resp = pay(port, ledger)
    assert resp.status == 200
    assert resp.body["receipt"]["settledBy"] == "echo_server"
  end

  test "an explicit :asset is used as given", %{port: port} do
    placeholder = "0x" <> String.duplicate("cd", 20)
    start_server(port: port, asset: placeholder)

    assert challenge(port)["asset"] == placeholder
  end

  test "the documented testnet rehearsal (Base Sepolia USDC) is paid",
       %{ledger: ledger, port: port} do
    start_server(port: port, network: @base_sepolia, asset: @base_sepolia_usdc)

    assert pay(port, ledger).status == 200
  end

  test "a network with no signable USDC raises, naming the option and the flag" do
    assert {:error, message} = EchoServer.default_asset(@base_sepolia)
    assert message =~ ":asset"
    assert message =~ "--asset"

    assert_raise ArgumentError, message, fn ->
      EchoServer.start_link(port: 4999, network: @base_sepolia)
    end
  end
end

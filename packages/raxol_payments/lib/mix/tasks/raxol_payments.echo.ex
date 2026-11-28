defmodule Mix.Tasks.RaxolPayments.Echo do
  @shortdoc "Run the x402 self-pay echo server"

  @moduledoc """
  Run `Raxol.Payments.EchoServer` for local agent validation.

      mix raxol_payments.echo --port 4002 --amount 10000

  ## Options

  - `--port` (integer, default 4002)
  - `--amount` (integer atomic units, default 10000 = $0.01 USDC)
  - `--pay-to` (hex address, default deterministic dev address)
  - `--asset` (hex address, default USDC on `--network`; a network with no
    USDC the x402 client signs for stops here and asks for `--asset`)
  - `--network` (CAIP-2, default `eip155:8453` / Base)

  Rehearse with a throwaway key. On the default network a client signs a real
  ERC-3009 transfer of Base USDC to `--pay-to`, valid on Base until the
  challenge's `validBefore` (an hour). This server never broadcasts it, but
  anyone holding the `x-payment` header can until then. For a signature worth
  nothing, use a testnet (Base Sepolia):

      mix raxol_payments.echo --network eip155:84532 \\
        --asset 0x036cbd53842c5426634e7929541ec2318f3dcf7e

  The server runs until you `Ctrl-C` it. Hit `GET /health` for a liveness
  ping; any other path triggers the 402 -> 200 dance.
  """

  use Mix.Task

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Xochi.Schemas

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          port: :integer,
          amount: :integer,
          pay_to: :string,
          asset: :string,
          network: :string
        ]
      )

    server_opts =
      opts
      |> Keyword.take([:port, :amount, :pay_to, :asset, :network])
      |> Keyword.update(:pay_to, nil, &with_0x/1)
      |> Keyword.update(:asset, nil, &with_0x/1)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Keyword.put_new_lazy(:asset, fn -> default_asset!(opts[:network]) end)

    case Raxol.Payments.EchoServer.start_link(server_opts) do
      {:ok, _pid} ->
        port = Keyword.get(server_opts, :port, 4002)
        Mix.shell().info("x402 echo listening on http://localhost:#{port} (Ctrl-C to stop)")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("failed to start echo server: #{inspect(reason)}")
    end
  end

  defp default_asset!(network) do
    case Raxol.Payments.EchoServer.default_asset(network) do
      {:ok, asset} -> asset
      {:error, message} -> Mix.raise(message)
    end
  end

  defp with_0x(nil), do: nil

  defp with_0x(addr) when is_binary(addr) do
    address = "0x" <> EIP712.normalize_address(addr)

    case Schemas.validate_eth_address(address) do
      :ok -> address
      {:error, :invalid_address} -> Mix.raise("not an EVM address: #{inspect(addr)}")
    end
  end
end

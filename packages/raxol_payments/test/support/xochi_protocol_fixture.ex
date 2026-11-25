defmodule Raxol.Payments.Test.XochiProtocolFixture do
  @moduledoc """
  Shared fixtures for the `Protocols.Xochi` tests: the exact_input request the
  stubbed quotes answer, a real anvil-key wallet, an echoing plug, and
  canonical ERC-3009 and Permit2 origin pulls.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Test.XochiIntentFixture
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  @key_env "RAXOL_XOCHI_DOMAIN_TEST_KEY"

  defmodule RealWallet do
    @moduledoc "Signs with the anvil key in `RAXOL_XOCHI_DOMAIN_TEST_KEY` (see `put_real_wallet_key/1`)."
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_XOCHI_DOMAIN_TEST_KEY"
  end

  @doc "Anvil's first public test key and its address."
  def anvil_key, do: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  def anvil_addr, do: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  @doc "The universal Permit2 deployment."
  def permit2_address, do: "0x000000000022D473030F116dDEE9F6B43aC78BA3"

  @doc "The solver spender a Permit2 pull names (pin it via `:pull_solver_allowlist`)."
  def permit2_spender, do: "0x000000000000000000000000000000000000dEaD"

  @doc "ExUnit setup: give `RealWallet` the anvil key for this test."
  def put_real_wallet_key(_context) do
    System.put_env(@key_env, anvil_key())
    on_exit(fn -> System.delete_env(@key_env) end)
    :ok
  end

  # The exact_input request every stubbed quote below answers.
  def request(wallet, overrides \\ []) do
    struct!(
      %QuoteRequest{
        wallet: wallet,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      },
      overrides
    )
  end

  # The Riddler-shaped intent for `request(wallet)`, quoting 990000 out.
  def intent_eip712(wallet), do: XochiIntentFixture.eip712(request(wallet), "990000")

  def echo_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "submitted"}))
    end
  end

  # A canonical ERC-3009 ReceiveWithAuthorization pull (all six signed fields, a
  # future validBefore). `overrides` may carry :message, :domain, :primary_type,
  # :types to exercise the envelope/expiry binding.
  def canonical_erc3009_pull(overrides \\ %{}) do
    valid_before = Integer.to_string(System.system_time(:second) + 600)

    message =
      Map.merge(
        %{
          "from" => anvil_addr(),
          "to" => anvil_addr(),
          "value" => "1000000",
          "validAfter" => "0",
          "validBefore" => valid_before,
          "nonce" => "0x" <> String.duplicate("00", 31) <> "01"
        },
        Map.get(overrides, :message, %{})
      )

    domain =
      Map.merge(
        %{
          "name" => "USD Coin",
          "version" => "2",
          "chainId" => 8453,
          "verifyingContract" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        },
        Map.get(overrides, :domain, %{})
      )

    %{
      "domain" => domain,
      "primaryType" => Map.get(overrides, :primary_type, "ReceiveWithAuthorization"),
      "types" =>
        Map.get(overrides, :types, %{
          "ReceiveWithAuthorization" => [
            %{"name" => "from", "type" => "address"},
            %{"name" => "to", "type" => "address"},
            %{"name" => "value", "type" => "uint256"},
            %{"name" => "validAfter", "type" => "uint256"},
            %{"name" => "validBefore", "type" => "uint256"},
            %{"name" => "nonce", "type" => "bytes32"}
          ]
        }),
      "message" => message
    }
  end

  # A canonical Permit2 PermitWitnessTransferFrom pull (future deadline).
  def canonical_permit2_pull(overrides \\ %{}) do
    deadline = Integer.to_string(System.system_time(:second) + 600)

    message =
      Map.merge(
        %{
          "permitted" => %{
            "token" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
            "amount" => "1000000"
          },
          "spender" => "0x000000000000000000000000000000000000dEaD",
          "nonce" => "1",
          "deadline" => deadline,
          "witness" => %{"orderId" => "0x" <> String.duplicate("00", 32)}
        },
        Map.get(overrides, :message, %{})
      )

    %{
      "domain" =>
        Map.merge(
          %{
            "name" => "Permit2",
            "chainId" => 8453,
            "verifyingContract" => Permit2.verifying_contract()
          },
          Map.get(overrides, :domain, %{})
        ),
      "primaryType" => Map.get(overrides, :primary_type, "PermitWitnessTransferFrom"),
      "types" =>
        Map.get(overrides, :types, %{
          "PermitWitnessTransferFrom" => [
            %{"name" => "permitted", "type" => "TokenPermissions"},
            %{"name" => "spender", "type" => "address"},
            %{"name" => "nonce", "type" => "uint256"},
            %{"name" => "deadline", "type" => "uint256"},
            %{"name" => "witness", "type" => "OriginPullWitness"}
          ],
          "TokenPermissions" => [
            %{"name" => "token", "type" => "address"},
            %{"name" => "amount", "type" => "uint256"}
          ],
          "OriginPullWitness" => [%{"name" => "orderId", "type" => "bytes32"}]
        }),
      "message" => message
    }
  end
end

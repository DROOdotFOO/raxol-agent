defmodule Raxol.Payments.Protocols.XochiPullPinDefaultTest do
  # async: false -- sets the global :deployment, :pull_require_solver_pin and
  # :pull_solver_allowlist, and XOCHI_PULL_REQUIRE_SOLVER_PIN.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.PullContracts
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  @signer "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  defmodule SignerWallet do
    @moduledoc false
    def address, do: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  end

  setup do
    for key <- [:deployment, :pull_require_solver_pin, :pull_solver_allowlist] do
      previous = Application.fetch_env(:raxol_payments, key)
      Application.delete_env(:raxol_payments, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol_payments, key, value)
          :error -> Application.delete_env(:raxol_payments, key)
        end
      end)
    end

    previous_env = System.get_env("XOCHI_PULL_REQUIRE_SOLVER_PIN")
    System.delete_env("XOCHI_PULL_REQUIRE_SOLVER_PIN")

    on_exit(fn ->
      if previous_env,
        do: System.put_env("XOCHI_PULL_REQUIRE_SOLVER_PIN", previous_env),
        else: System.delete_env("XOCHI_PULL_REQUIRE_SOLVER_PIN")
    end)
  end

  describe "an unpinned ERC-3009 pull (no allowlist)" do
    test "is accepted by default outside production" do
      Application.put_env(:raxol_payments, :deployment, :development)

      assert :ok = Xochi.validate_pull(erc3009_quote(), request(), SignerWallet)
    end

    test "is rejected by default in production" do
      Application.put_env(:raxol_payments, :deployment, :production)

      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.validate_pull(erc3009_quote(), request(), SignerWallet)
    end

    test "explicit config wins over the production default, both ways" do
      Application.put_env(:raxol_payments, :deployment, :production)
      Application.put_env(:raxol_payments, :pull_require_solver_pin, false)
      assert :ok = Xochi.validate_pull(erc3009_quote(), request(), SignerWallet)

      Application.put_env(:raxol_payments, :deployment, :development)
      Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.validate_pull(erc3009_quote(), request(), SignerWallet)
    end
  end

  describe "origin_pull_pin_env_config!/0 with XOCHI_PULL_REQUIRE_SOLVER_PIN unset" do
    test "requires the pin in production" do
      Application.put_env(:raxol_payments, :deployment, :production)

      assert Xochi.origin_pull_pin_env_config!() == [
               pull_solver_allowlist: PullContracts.pull_recipients(),
               pull_require_solver_pin: true
             ]
    end

    test "an explicit false still refuses a fail-open production boot" do
      Application.put_env(:raxol_payments, :deployment, :production)
      System.put_env("XOCHI_PULL_REQUIRE_SOLVER_PIN", "false")

      assert_raise ArgumentError, ~r/fail-open/, fn -> Xochi.origin_pull_pin_env_config!() end
    end
  end

  describe "origin_pull_fail_open?/2 and assert_origin_pull_pinned!/2" do
    @pinned ["0x8d7d8AcfC25E999273394F7Ab44C239806724e2B"]

    test "an empty allowlist without a required pin is fail-open and refused" do
      # nil, blank and non-binary entries normalize away to an empty list.
      for allowlist <- [[], nil, ["", "  "], [nil, 123]] do
        assert Xochi.origin_pull_fail_open?(allowlist, false)

        assert_raise ArgumentError, ~r/solver pin is not configured/, fn ->
          Xochi.assert_origin_pull_pinned!(allowlist, false)
        end
      end
    end

    test "a required pin or a populated allowlist is not fail-open" do
      for {allowlist, require_pin?} <- [{[], true}, {@pinned, false}, {@pinned, true}] do
        refute Xochi.origin_pull_fail_open?(allowlist, require_pin?)
        assert :ok = Xochi.assert_origin_pull_pinned!(allowlist, require_pin?)
      end
    end
  end

  defp request do
    %QuoteRequest{
      wallet: @signer,
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
      from_amount: "1000000",
      settlement_preference: "public"
    }
  end

  defp erc3009_quote do
    valid_before = Integer.to_string(System.system_time(:second) + 600)

    %QuoteResponse{
      intent_id: "xi_pin_default",
      quote_id: "xq_pin_default",
      can_solve: true,
      payment_method: "erc3009",
      to_amount: "990000",
      pull_authorization: %{
        "domain" => %{
          "name" => "USD Coin",
          "version" => "2",
          "chainId" => 8453,
          "verifyingContract" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        },
        "primaryType" => "ReceiveWithAuthorization",
        "types" => %{
          "ReceiveWithAuthorization" => [
            %{"name" => "from", "type" => "address"},
            %{"name" => "to", "type" => "address"},
            %{"name" => "value", "type" => "uint256"},
            %{"name" => "validAfter", "type" => "uint256"},
            %{"name" => "validBefore", "type" => "uint256"},
            %{"name" => "nonce", "type" => "bytes32"}
          ]
        },
        "message" => %{
          "from" => @signer,
          "to" => "0x000000000000000000000000000000000000dEaD",
          "value" => "1000000",
          "validAfter" => "0",
          "validBefore" => valid_before,
          "nonce" => "0x" <> String.duplicate("00", 31) <> "01"
        }
      }
    }
  end
end

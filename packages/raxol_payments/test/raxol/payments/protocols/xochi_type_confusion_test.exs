defmodule Raxol.Payments.Protocols.XochiTypeConfusionTest do
  @moduledoc """
  The served EIP-712 payloads a hostile quote endpoint can send to get the
  wallet to sign something other than the intent or pull it checked: extra types
  that move the hashed root to a USDC `Permit`, a retyped field, an extra
  signable field, and a domain that is not the expected one. Each is refused
  before the wallet is called.
  """
  # async: false -- sets the global solver allowlist and pin.
  use ExUnit.Case, async: false

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Test.XochiIntentFixture
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  @agent "0x1111111111111111111111111111111111111111"
  @attacker "0x000000000000000000000000000000000000bEEF"
  @solver "0x000000000000000000000000000000000000dEaD"
  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @max_uint256 Integer.to_string(Integer.pow(2, 256) - 1)

  defmodule TrapWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet

    @impl true
    def address, do: "0x1111111111111111111111111111111111111111"
    @impl true
    def chain_id, do: 8453
    @impl true
    def sign_message(_message), do: send_and_fail(:sign_message)
    @impl true
    def sign_typed_data(_domain, _types, _message), do: send_and_fail(:sign_typed_data)
    @impl true
    def sign_hash(_digest), do: send_and_fail(:sign_hash)

    defp send_and_fail(kind) do
      send(self(), {:wallet_called, kind})
      {:error, :trap}
    end
  end

  setup do
    for key <- [:pull_solver_allowlist, :pull_require_solver_pin] do
      previous = Application.fetch_env(:raxol_payments, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol_payments, key, value)
          :error -> Application.delete_env(:raxol_payments, key)
        end
      end)
    end

    Application.put_env(:raxol_payments, :pull_solver_allowlist, [@solver])
    Application.put_env(:raxol_payments, :pull_require_solver_pin, true)
    :ok
  end

  describe "the intent: the reviewer's Permit-as-root payload" do
    test "a Dummy cycle that makes USDC Permit the hashed root is refused, wallet never called" do
      request = request()
      honest = XochiIntentFixture.eip712(request, "990000")

      hostile =
        honest
        |> Map.put("domain", %{
          "name" => "USD Coin",
          "version" => "2",
          "chainId" => 8453,
          "verifyingContract" => @usdc_base
        })
        |> update_in(["types"], fn types ->
          types
          |> Map.update!("XochiIntent", &(&1 ++ [%{"name" => "link", "type" => "Dummy"}]))
          |> Map.put("Dummy", [%{"name" => "x", "type" => "XochiIntent"}])
          |> Map.put("Permit", permit_fields())
        end)
        |> update_in(["message"], fn message ->
          Map.merge(message, %{
            "owner" => @agent,
            "spender" => @attacker,
            "value" => @max_uint256,
            "nonce" => "0",
            "link" => %{"x" => %{}}
          })
        end)

      # Hashed as served, the root would be `Permit`: the signature would be a
      # USDC permit for the attacker. The served types must be exactly v3's.
      assert EIP712.primary_type(Xochi.eip712_types(hostile)) == "Permit"

      assert_refused_intent(quote_for(hostile), request, :intent_type)
    end

    test "an extra signable message field is refused" do
      request = request()
      eip712 = XochiIntentFixture.eip712(request, "990000", message: %{"spender" => @attacker})
      assert_refused_intent(quote_for(eip712), request, :intent_fields)
    end

    test "a retyped field is refused" do
      request = request()

      eip712 =
        request
        |> XochiIntentFixture.eip712("990000")
        |> update_in(["types", "XochiIntent"], fn fields ->
          Enum.map(fields, fn
            %{"name" => "wallet"} = f -> %{f | "type" => "string"}
            f -> f
          end)
        end)

      assert_refused_intent(quote_for(eip712), request, :intent_type)
    end

    test "a domain that is not the v3 Xochi domain on the origin chain is refused" do
      request = request()

      for {key, value, field} <- [
            {"name", "USD Coin", :name},
            {"version", "2", nil},
            {"chainId", 1, :chain_id}
          ] do
        eip712 =
          request
          |> XochiIntentFixture.eip712("990000")
          |> put_in(["domain", key], value)

        assert {:error, {:intent_mismatch, {:intent_domain, got}}} =
                 Xochi.sign_intent(quote_for(eip712), TrapWallet, request)

        if field, do: assert(got == field), else: assert(got in [:version, :salt])
        refute_received {:wallet_called, _}
      end

      with_contract =
        request
        |> XochiIntentFixture.eip712("990000")
        |> put_in(["domain", "verifyingContract"], @usdc_base)

      assert {:error, {:intent_mismatch, {:intent_domain, :fields}}} =
               Xochi.sign_intent(quote_for(with_contract), TrapWallet, request)

      refute_received {:wallet_called, _}
    end
  end

  describe "the ERC-3009 pull: the reviewer's retyped-nonce payload" do
    test "nonce: Dummy with a Dummy cycle (Permit as root) is refused, wallet never called" do
      request = request()

      pull =
        erc3009_pull()
        |> update_in(["types"], fn types ->
          types
          |> Map.update!("ReceiveWithAuthorization", fn fields ->
            Enum.map(fields, fn
              %{"name" => "nonce"} = f -> %{f | "type" => "Dummy"}
              f -> f
            end)
          end)
          |> Map.put("Dummy", [%{"name" => "x", "type" => "ReceiveWithAuthorization"}])
          |> Map.put("Permit", permit_fields())
        end)
        |> update_in(["message"], fn message ->
          Map.merge(message, %{
            "nonce" => %{"x" => %{}},
            "owner" => @agent,
            "spender" => @attacker,
            "deadline" => "9999999999"
          })
        end)

      assert_refused_pull(pull, request, :pull_type)
    end

    test "an extra signable field is refused" do
      pull = update_in(erc3009_pull(), ["message"], &Map.put(&1, "spender", @attacker))
      assert_refused_pull(pull, request(), :pull_fields)
    end

    test "a domain other than USDC's own on the origin chain is refused" do
      for {key, value, field} <- [
            {"name", "USDC Permit", {:pull_domain, :name}},
            {"version", "1", {:pull_domain, :version}},
            {"chainId", 1, :pull_chain},
            {"verifyingContract", @attacker, :pull_token}
          ] do
        pull = put_in(erc3009_pull(), ["domain", key], value)
        assert_refused_pull(pull, request(), field)
      end
    end
  end

  describe "the Permit2 pull" do
    test "a PermitSingle allowance served under the permit2 method is refused" do
      pull =
        permit2_pull()
        |> Map.put("primaryType", "PermitSingle")
        |> Map.put("types", %{
          "PermitSingle" => [
            %{"name" => "details", "type" => "PermitDetails"},
            %{"name" => "spender", "type" => "address"},
            %{"name" => "sigDeadline", "type" => "uint256"}
          ],
          "PermitDetails" => [
            %{"name" => "token", "type" => "address"},
            %{"name" => "amount", "type" => "uint160"},
            %{"name" => "expiration", "type" => "uint48"},
            %{"name" => "nonce", "type" => "uint48"}
          ]
        })

      assert_refused_pull(pull, request(), :pull_type, "permit2")
    end

    test "a domain with a version, or another name, is refused" do
      versioned = put_in(permit2_pull(), ["domain", "version"], "1")
      assert_refused_pull(versioned, request(), {:pull_domain, :fields}, "permit2")

      renamed = put_in(permit2_pull(), ["domain", "name"], "Permit3")
      assert_refused_pull(renamed, request(), {:pull_domain, :name}, "permit2")
    end
  end

  describe "the encoder" do
    test "refuses to guess a root for a types map with none or several" do
      cycle = %{"A" => [{"b", "B"}], "B" => [{"a", "A"}]}
      assert {:error, :no_primary_type} = EIP712.hash(%{name: "x"}, cycle, %{})

      two_roots = %{"A" => [{"v", "uint256"}], "B" => [{"v", "uint256"}]}
      assert {:error, :no_primary_type} = EIP712.hash(%{name: "x"}, two_roots, %{})
    end

    test "hash/4 hashes the root the caller names, or refuses an undefined one" do
      types = %{"A" => [{"v", "uint256"}]}

      assert EIP712.hash(%{name: "x"}, "A", types, %{"v" => 1}) ==
               EIP712.hash(%{name: "x"}, types, %{"v" => 1})

      assert {:error, {:unknown_primary_type, "Permit"}} =
               EIP712.hash(%{name: "x"}, "Permit", types, %{"v" => 1})
    end

    test "the canonical kinds encode to their published typehashes" do
      for kind <- [Xochi.intent_kind(), Xochi.permit2_kind()] do
        assert EIP712.type_hash(kind.primary, kind.types) == kind.type_hash
      end
    end
  end

  defp assert_refused_intent(quote_resp, request, field) do
    assert {:error, {:intent_mismatch, ^field}} = Xochi.validate_intent(quote_resp, request)

    assert {:error, {:intent_mismatch, ^field}} =
             Xochi.sign_intent(quote_resp, TrapWallet, request)

    refute_received {:wallet_called, _}
  end

  defp assert_refused_pull(pull, request, field, method \\ "erc3009") do
    quote_resp = %{
      quote_for(XochiIntentFixture.eip712(request, "990000"))
      | payment_method: method
    }

    quote_resp = %{quote_resp | pull_authorization: pull}

    assert {:error, {:authorization_mismatch, ^field}} =
             Xochi.validate_pull(quote_resp, request, TrapWallet)

    assert {:error, {:authorization_mismatch, ^field}} =
             Xochi.sign_intent(quote_resp, TrapWallet, request)

    refute_received {:wallet_called, _}
  end

  defp request do
    %QuoteRequest{
      wallet: @agent,
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: @usdc_base,
      to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
      from_amount: "1000000",
      settlement_preference: "public"
    }
  end

  defp quote_for(eip712) do
    %QuoteResponse{
      intent_id: "xi_" <> String.duplicate("a", 32),
      quote_id: "xq_" <> String.duplicate("b", 32),
      can_solve: true,
      to_amount: "990000",
      eip712_data: eip712
    }
  end

  defp permit_fields do
    [
      %{"name" => "owner", "type" => "address"},
      %{"name" => "spender", "type" => "address"},
      %{"name" => "value", "type" => "uint256"},
      %{"name" => "nonce", "type" => "uint256"},
      %{"name" => "deadline", "type" => "uint256"}
    ]
  end

  defp erc3009_pull do
    %{
      "domain" => %{
        "name" => "USD Coin",
        "version" => "2",
        "chainId" => 8453,
        "verifyingContract" => @usdc_base
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
        "from" => @agent,
        "to" => @solver,
        "value" => "1000000",
        "validAfter" => "0",
        "validBefore" => Integer.to_string(System.system_time(:second) + 600),
        "nonce" => "0x" <> String.duplicate("00", 31) <> "01"
      }
    }
  end

  defp permit2_pull do
    %{
      "domain" => %{
        "name" => "Permit2",
        "chainId" => 8453,
        "verifyingContract" => Raxol.Payments.Protocols.Permit2.verifying_contract()
      },
      "primaryType" => "PermitWitnessTransferFrom",
      "types" => %{
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
      },
      "message" => %{
        "permitted" => %{"token" => @usdc_base, "amount" => "1000000"},
        "spender" => @solver,
        "nonce" => "1",
        "deadline" => Integer.to_string(System.system_time(:second) + 600),
        "witness" => %{"orderId" => "0x" <> String.duplicate("cd", 32)}
      }
    }
  end
end

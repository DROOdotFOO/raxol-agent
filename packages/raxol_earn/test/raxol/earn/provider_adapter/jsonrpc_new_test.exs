defmodule Raxol.Earn.ProviderAdapter.JSONRPCNewTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.ProviderAdapter.JSONRPC

  # Anvil's public account 0.
  @key Base.decode16!("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
         case: :lower
       )

  test "derives the address and keeps the key wrapped" do
    %{config: config} = JSONRPC.new(chains: %{8453 => "https://rpc.example/k"}, private_key: @key)

    assert config.address == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    refute inspect(config) =~ "ac0974"
    refute inspect(config) =~ "rpc.example"
  end

  test "an invalid key raises without echoing it" do
    error =
      assert_raise ArgumentError, fn ->
        JSONRPC.new(chains: %{}, private_key: <<0::256>>)
      end

    assert error.message == "private_key is not a valid secp256k1 key"
  end
end

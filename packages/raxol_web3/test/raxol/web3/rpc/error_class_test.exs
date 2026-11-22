defmodule Raxol.Web3.RPC.ErrorClassTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Backend.Solana.RPC, as: SolanaRPC
  alias Raxol.Web3.RPC.ErrorClass

  test "an error object is classified only by an integer code" do
    assert ErrorClass.of_error(%{"code" => -32_601}) == :not_found
    assert ErrorClass.of_error(%{"code" => -32_005, "message" => "slow down"}) == :rate_limit
    assert ErrorClass.of_error(%{"code" => 401}) == :auth
    assert ErrorClass.of_error(%{"code" => "-32601"}) == :unknown
    assert ErrorClass.of_error(%{"code" => -32_601.0}) == :unknown
    # The shapes JSON-RPC does not allow stay unclassified, as before.
    assert ErrorClass.of_error(429) == :unknown
    assert ErrorClass.of_error(%{"code" => %{"code" => 401}}) == :unknown
    assert ErrorClass.of_error([%{"code" => 401}]) == :unknown
    assert ErrorClass.of_error(nil) == :unknown
  end

  test "a bare code is classified, and only an integer one" do
    assert ErrorClass.of_code(-32_601) == :not_found
    assert ErrorClass.of_code(-32_004) == :unknown
    assert ErrorClass.of_code(%{"code" => 401}) == :unknown
    assert ErrorClass.of_code(nil) == :unknown
  end

  test "an override is consulted before the shared table" do
    assert ErrorClass.of_code(-32_004, %{-32_004 => :not_found}) == :not_found
    assert ErrorClass.of_code(-32_601, %{-32_601 => :unknown}) == :unknown
    assert SolanaRPC.error_class(-32_004) == :not_found
    assert SolanaRPC.error_class(-32_005) == :rate_limit
    assert SolanaRPC.error_class("-32004") == :unknown
  end
end

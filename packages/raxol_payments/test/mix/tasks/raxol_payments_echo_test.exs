defmodule Mix.Tasks.RaxolPayments.EchoTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.RaxolPayments.Echo

  # Base Sepolia has no USDC the x402 client signs for, so the task stops
  # before it starts a server: nothing listens and nothing is signed.
  test "a network with no signable USDC is one line that names the flag, not the option" do
    error = assert_raise Mix.Error, fn -> Echo.run(["--network", "eip155:84532"]) end

    assert error.message ==
             "no USDC the x402 client signs for is registered on eip155:84532; " <>
               "pass the asset contract with --asset"

    refute error.message =~ ":asset"
    refute error.message =~ "\n"
  end
end

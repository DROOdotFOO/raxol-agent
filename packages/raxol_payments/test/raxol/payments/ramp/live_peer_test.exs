defmodule Raxol.Payments.Ramp.LivePeerTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Raxol.Payments.Ramps
  @moduletag :live_peer

  test "public read-only discovery with explicitly supplied runtime context" do
    # No defaults that claim an installed extension or verified identity.
    # A trusted operator sets readiness only after checking all Peer setup.
    assert System.fetch_env!("PEER_INTERACTION_READY") == "true"
    user = System.fetch_env!("PEER_USER_ADDRESS")
    orchestrator = System.fetch_env!("PEER_ORCHESTRATOR_ADDRESS")
    fiat = %{"kind" => "fiat", "currency" => "USD", "decimals" => 2}

    intent = %{
      "contract_version" => "ramp/1",
      "kind" => "intent",
      "direction" => "onramp",
      "fiat" => fiat,
      "crypto" => %{
        "kind" => "crypto",
        "chain_id" => "eip155:8453",
        "asset_id" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        "symbol" => "USDC",
        "decimals" => 6
      },
      "exact" => %{"side" => "fiat", "money" => %{"asset" => fiat, "atomic" => "10000"}},
      "recipient" => user
    }

    assert {:ok, offers} =
             Ramps.discover(intent, %{
               user: user,
               orchestrator: orchestrator,
               interaction_ready: true,
               ready_rails: String.split(System.fetch_env!("PEER_READY_RAILS"), ",", trim: true)
             })

    assert Enum.all?(offers, &(&1.availability["state"] == "available"))
  end
end

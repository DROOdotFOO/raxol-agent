defmodule Raxol.Payments.Actions.Payments.DiscoverRamps do
  @moduledoc "Read-only sanitized Peer ramp action."
  @compile {:no_warn_undefined, Raxol.Agent.Action}
  use Raxol.Agent.Action,
    name: "payment_discover_ramps",
    description: "Discover fresh Peer ramp offers without submitting a payment",
    schema: [
      input: [intent: [type: :map, required: true, description: "Snake_case ramp/1 intent"]],
      output: [offers: [type: {:list, :map}]]
    ]

  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramps

  @impl true
  def run(%{intent: intent}, context) do
    with {:ok, offers} <- Ramps.discover(intent, Map.get(context, :ramps, %{})) do
      {:ok, %{offers: Enum.map(offers, &Ramp.to_wire/1)}}
    end
  end

  def run(_, _), do: {:error, :invalid_request}
end

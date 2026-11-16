defmodule Raxol.Payments.Actions.Payments.PreviewRamp do
  @moduledoc "Read-only sanitized Peer ramp action."
  @compile {:no_warn_undefined, Raxol.Agent.Action}
  use Raxol.Agent.Action,
    name: "payment_preview_ramp",
    description: "Requote and preview a Peer ramp without submitting a payment",
    schema: [
      input: [
        intent: [type: :map, required: true, description: "Snake_case ramp/1 intent"],
        offer_ref: [type: :string, required: true],
        revision: [type: :string, required: true]
      ],
      output: [preview: [type: :map]]
    ]

  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramps

  @impl true
  def run(%{intent: intent, offer_ref: ref, revision: revision}, context) do
    with {:ok, preview} <- Ramps.preview(intent, ref, revision, Map.get(context, :ramps, %{})) do
      {:ok, %{preview: Ramp.to_wire(preview)}}
    end
  end

  def run(_, _), do: {:error, :invalid_request}
end

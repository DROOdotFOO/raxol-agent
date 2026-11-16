defmodule Raxol.Payments.Ramps do
  @moduledoc """
  Read-only ramp discovery and preview. Execution, resume and recovery are
  intentionally absent until R2–R4 (raxol #1358, #1360, #1359).

  Trusted context configures the provider and dependencies; action parameters
  cannot supply transport options, browser readiness, or provider configuration.
  """
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer

  @spec discover(map() | struct(), map()) :: {:ok, [struct()]} | {:error, atom()}
  def discover(intent, context) do
    case validate(intent) do
      {:ok, %Ramp.Intent{} = clean} ->
        provider(context).capabilities(Map.put(context, :intent, clean))

      _ ->
        {:error, :invalid_request}
    end
  end

  @spec preview(map() | struct(), String.t(), String.t(), map()) ::
          {:ok, struct()} | {:error, atom()}
  def preview(intent, offer_ref, revision, context) do
    case validate(intent) do
      {:ok, %Ramp.Intent{} = clean} ->
        provider(context).preview(clean, offer_ref, revision, context)

      _ ->
        {:error, :invalid_request}
    end
  end

  defp provider(context), do: Map.get(context, :ramp_provider, Peer)
  defp validate(%Ramp.Intent{} = intent), do: intent |> Ramp.to_wire() |> Ramp.decode()
  defp validate(intent), do: Ramp.decode(intent)
end

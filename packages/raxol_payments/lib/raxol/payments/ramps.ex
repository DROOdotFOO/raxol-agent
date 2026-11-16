defmodule Raxol.Payments.Ramps do
  @moduledoc """
  Ramp discovery, preview and approval-gated onramp handoff.

  `run/3` takes an approval containing `:quote_id` and `:command` (the
  expected revision and idempotency key). `resume/2` takes the opaque
  `:action_ref` and `:command` in context. The trusted context supplies the
  validated preview, spending policy, explicit confirmation callback,
  authenticated widget port and principal-scoped checkpoint store.

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

  @doc "Begin an explicitly approved onramp using the trusted runtime context."
  def run(operation, %{quote_id: quote, command: command}, context),
    do: provider(context).approve(operation, quote, command, context)

  def run(_, _, _), do: {:error, :invalid_request}

  @doc "Resume the existing operation from its public pending-action reference."
  def resume(operation, %{action_ref: ref, command: command} = context),
    do: provider(context).recover(operation, ref, command, context)

  def resume(_, _), do: {:error, :invalid_request}

  defp provider(context), do: Map.get(context, :ramp_provider, Peer)
  defp validate(%Ramp.Intent{} = intent), do: intent |> Ramp.to_wire() |> Ramp.decode()
  defp validate(intent), do: Ramp.decode(intent)
end

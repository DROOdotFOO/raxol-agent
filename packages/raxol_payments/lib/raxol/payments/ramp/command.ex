defmodule Raxol.Payments.Ramp.CommandCheck do
  @moduledoc "Contract preflight only. Does not execute commands or store receipts."
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Coherence
  alias Raxol.Payments.Ramp.Schema

  def check(snapshot, command, receipt \\ nil) do
    with {:ok, %{kind: "command"}} <- Ramp.decode(command),
         {:ok, previous} <- previous(receipt) do
      check_valid(snapshot, command, previous)
    else
      {:error, :invalid_receipt} -> :invalid_receipt
      _ -> :invalid_command
    end
  end

  # TypeScript validates receipt shape without executing it or checking the
  # snapshot's advertised actions against the receipt.
  defp previous(nil), do: {:ok, nil}

  defp previous(%{"command" => command}) do
    case Schema.parse(command) do
      {:ok, %{"kind" => "command"} = clean} -> {:ok, clean}
      _ -> {:error, :invalid_receipt}
    end
  end

  defp previous(_), do: {:error, :invalid_receipt}

  defp check_valid(s, c, previous) do
    cond do
      s["operation_id"] != c["operation_id"] ->
        :session_conflict

      previous && previous["context"]["idempotency_key"] == c["context"]["idempotency_key"] ->
        if previous == c, do: :replayed, else: :session_conflict

      s["revision"] != c["context"]["expected_revision"] ->
        :session_conflict

      allowed?(s, c) ->
        :accepted

      true ->
        :action_not_allowed
    end
  end

  defp allowed?(s, c) do
    leg = s[c["leg"]]
    action = c["action"]

    leg != nil and not s["terminal"] and action in s["allowed_actions"] and
      recovery_allowed?(leg, action) and terminal_allowed?(leg, c) and
      (not Enum.any?(Coherence.legs(s), &(&1["state"] == "in_doubt")) or action == "check_status") and
      (action == "check_status" or String.ends_with?(action, "route") == (c["leg"] == "xochi"))
  end

  defp recovery_allowed?(leg, action),
    do: action not in ~w(recover_peer recover_route) or Coherence.recoverable?(leg)

  defp terminal_allowed?(leg, c) do
    recovery = if c["leg"] == "peer", do: "recover_peer", else: "recover_route"

    leg["state"] not in ~w(completed failed refunded skipped) or c["action"] == "check_status" or
      (Coherence.recoverable?(leg) and c["action"] == recovery)
  end
end

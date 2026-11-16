defmodule Raxol.Payments.Ramp.Recovery do
  @moduledoc "Shared command claims and sanitized terminal checkpoint receipts."
  alias Raxol.Payments.Checkpoint

  # Atomic store claims cover both directions and all operations for one principal.
  # Keep the claim after completion: a replay must never become another submission.
  def claim(context, operation, action, command) do
    key = "peer_command:" <> Checkpoint.derive_key([command.idempotency_key])

    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({operation, action, command}, [:deterministic])
      )

    claim = %{operation_id: operation, digest: digest}

    case Checkpoint.put_new(context.checkpoint, key, claim) do
      :ok ->
        :new

      _ ->
        case Checkpoint.fetch(context.checkpoint, key) do
          {:ok, ^claim} -> :replayed
          _ -> :conflict
        end
    end
  end

  def reserve(context, operation, direction) do
    key = "peer_operation:" <> operation

    case Checkpoint.put_new(context.checkpoint, key, %{direction: direction}) do
      :ok ->
        :ok

      _ ->
        case Checkpoint.fetch(context.checkpoint, key) do
          {:ok, %{direction: ^direction}} -> :ok
          _ -> {:error, :session_conflict}
        end
    end
  end

  def close(%{snapshot: %{terminal: true} = snapshot} = record) do
    Map.merge(record, %{
      closed: true,
      receipt: %{
        operation_id: snapshot.operation_id,
        revision: snapshot.revision,
        direction: snapshot.direction,
        state: snapshot.peer["state"],
        updated_at: snapshot.updated_at
      }
    })
  end

  def close(record), do: record
  def conflict(record), do: {:error, :session_conflict, record.snapshot}
end

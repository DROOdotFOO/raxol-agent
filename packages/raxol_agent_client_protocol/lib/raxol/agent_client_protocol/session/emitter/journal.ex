defmodule Raxol.AgentClientProtocol.Session.Emitter.Journal do
  @moduledoc """
  The durable emitter: appends updates and turn boundaries to the session's
  single-publisher `Ext.Journal.Writer`, which fans them out to reattachers.

    * `emit/2` appends a `"session_update"` record, then notifies the origin
      connection directly, so updates have two delivery sites (origin direct,
      reattachers via the Writer); every delivered update is still durable.
      Ordering is the Writer's arrival order.
    * `turn_started/3` appends `"turn_started"` (prompt recorded as `[]`) and
      takes the Writer's cross-connection turn latch.
    * `turn_completed/3` appends `"turn_completed"` from the rendered response
      and releases the latch.

  With no live Writer every call degrades to notify-only or a no-op; a Writer
  failure never crashes the turn. Born-cancelled turns append nothing.
  """

  @behaviour Raxol.AgentClientProtocol.Session.Emitter

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate

  @impl true
  def emit(state, %SessionNotification{update: update} = notification) do
    payload = SessionUpdate.to_json(update)
    _ = append(state, "session_update", payload, taint_of(update))
    # Origin delivery: direct notify on the Session's own connection.
    _ = state.conn_mod.notify(state.conn, "session/update", notification)
    :ok
  end

  # An opaque update still delivers, but is not durable.
  def emit(state, notification) do
    _ = state.conn_mod.notify(state.conn, "session/update", notification)
    :ok
  end

  @impl true
  def turn_started(state, req, turn_id) do
    # Only a held latch refuses the turn; missing durability never does.
    case append(
           state,
           "turn_started",
           %{"turnId" => turn_id, "prompt" => prompt_blocks(req)},
           "user"
         ) do
      {:error, :turn_in_flight} -> {:error, :turn_in_flight}
      _other -> :ok
    end
  end

  @impl true
  def turn_completed(state, rendered, turn_id) do
    _ = append(state, "turn_completed", completed_payload(turn_id, rendered), "system")
    :ok
  end

  @impl true
  def steer_accepted(state, ref, request) do
    payload = %{
      "turnId" => Map.get(ref, :turn_id),
      "offset" => Map.get(ref, :offset),
      "payload" => %{
        "clientMsgId" => Map.get(ref, :client_msg_id),
        "text" => Map.get(request, :text)
      }
    }

    _ = append(state, "steer", payload, "user")
    :ok
  end

  # Stops the Writer; the journal store outlives it and a reattach respawns it.
  @impl true
  def reap(state) do
    case Writer.whereis(state.session_id) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp append(state, kind, payload, taint) do
    case Writer.whereis(state.session_id) do
      nil -> :ok
      writer -> safe_append(writer, kind, payload, taint)
    end
  end

  defp safe_append(writer, kind, payload, taint) do
    Writer.append(writer, kind, payload, taint)
  catch
    # A Writer that dies mid-call must not take down the turn task.
    kind_, reason -> {:caught, kind_, reason}
  end

  defp taint_of({:user_message_chunk, _}), do: "user"
  defp taint_of({:agent_message_chunk, _}), do: "agent"
  defp taint_of({:agent_thought_chunk, _}), do: "agent"
  defp taint_of({:plan, _}), do: "agent"
  defp taint_of({:tool_call, _}), do: "external"
  defp taint_of({:tool_call_update, _}), do: "external"
  defp taint_of(_other), do: "system"

  defp prompt_blocks(_req), do: []

  defp completed_payload(turn_id, {:ok, %PromptResponse{stop_reason: r}}),
    do: %{"turnId" => turn_id, "stopReason" => stop_reason_str(r)}

  defp completed_payload(turn_id, {:error, %Error{code: c, message: m}}),
    do: %{"turnId" => turn_id, "error" => %{"code" => c, "message" => m}}

  defp completed_payload(turn_id, _other),
    do: %{"turnId" => turn_id, "stopReason" => "end_turn"}

  defp stop_reason_str(r) when is_atom(r), do: Atom.to_string(r)
  defp stop_reason_str(r) when is_binary(r), do: r
  defp stop_reason_str(r), do: inspect(r)
end

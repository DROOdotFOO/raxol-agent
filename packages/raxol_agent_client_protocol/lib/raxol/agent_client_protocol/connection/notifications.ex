defmodule Raxol.AgentClientProtocol.Connection.Notifications do
  @moduledoc false
  # Inbound notifications, including the Connection-handled `$/cancel_request`
  # and `session/cancel`.

  require Logger

  alias Raxol.AgentClientProtocol.Connection.{Dispatch, Turns}
  alias Raxol.AgentClientProtocol.{Router, Telemetry}
  alias Raxol.AgentClientProtocol.Rpc.{Notification, RequestId}
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification

  @session_registry Raxol.AgentClientProtocol.SessionRegistry

  # `$/cancel_request` is protocol-layer and allowed before the handshake.
  @spec handle(map(), Notification.t(), non_neg_integer()) :: {:noreply, map()}
  def handle(state, %Notification{method: "$/cancel_request", params: params}, _rx_seq) do
    case CancelRequestNotification.from_json(params || %{}) do
      {:ok, %{request_id: cancel_id}} -> {:noreply, cancel_inbound(state, cancel_id)}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle(%{phase: phase} = state, %Notification{method: method}, _rx_seq)
      when phase != :initialized do
    Logger.debug("ACP: notification #{method} dropped pre-handshake")
    {:noreply, state}
  end

  def handle(state, %Notification{method: "session/cancel", params: params}, rx_seq) do
    with {:ok, %{session_id: session_id}} <- CancelNotification.from_json(params || %{}) do
      case lookup_session(session_id) do
        [{spid, _} | _] -> GenServer.cast(spid, {:acp_session_cancel, rx_seq})
        [] -> Logger.debug("ACP: session/cancel for unknown session #{inspect(session_id)}")
      end
    end

    {:noreply, state}
  end

  def handle(state, %Notification{method: method, params: params}, rx_seq) do
    case Router.decode(state.role, :notification, method, params) do
      {:error, _reason} ->
        Logger.debug("ACP: unknown/invalid notification #{method} dropped")
        Telemetry.execute([:raxol, :acp, :unknown_notification], %{method: method})
        {:noreply, state}

      # session/update is stamped and delivered to the turn owner from this
      # process before any handler runs.
      {:ok, {:session_update, notif} = dispatchable} ->
        {stamp, state} = Turns.stamp_update(state, notif, rx_seq)
        spawn_notification(state, method, dispatchable, stamp)

      {:ok, dispatchable} ->
        spawn_notification(state, method, dispatchable, nil)
    end
  end

  # No reply obligation, so an over-capacity spawn is dropped, not answered.
  defp spawn_notification(state, method, dispatchable, stamp) do
    case Dispatch.start(state, dispatchable, %{Dispatch.ctx(state) | delivery_stamp: stamp}) do
      {:error, reason} ->
        Logger.warning(
          "ACP: notification #{method} dropped — dispatch task_sup saturated (#{inspect(reason)})"
        )

        Telemetry.execute([:raxol, :acp, :notification_shed], %{method: method})
        {:noreply, state}

      {:ok, task} ->
        {:noreply,
         %{state | task_index: Map.put(state.task_index, task.ref, {:notification, method})}}
    end
  end

  # Marks the entry cancelled first, then stops its task or tells its adopter.
  defp cancel_inbound(state, cancel_id) do
    case Map.get(state.pending_in, cancel_id) do
      nil ->
        Logger.debug(
          "ACP: $/cancel_request for unknown/finished id #{RequestId.display(cancel_id)}"
        )

        state

      entry ->
        pending_in = Map.put(state.pending_in, cancel_id, %{entry | cancelled?: true})
        stop_cancelled(state, entry)
        %{state | pending_in: pending_in}
    end
  end

  defp stop_cancelled(_state, %{adopter: {apid, _mon}, reply_ref: rref}),
    do: send(apid, {:acp_reply_cancelled, rref})

  defp stop_cancelled(_state, %{task_pid: nil}), do: :ok

  defp stop_cancelled(state, %{task_pid: pid}),
    do: Task.Supervisor.terminate_child(state.task_sup, pid)

  defp lookup_session(session_id) do
    case Process.whereis(@session_registry) do
      nil -> []
      _pid -> Registry.lookup(@session_registry, {self(), session_id})
    end
  end
end

defmodule Raxol.AgentClientProtocol.Connection.Notifications do
  @moduledoc false
  # Inbound notifications, including the Connection-handled `$/cancel_request`
  # and `session/cancel`.

  require Logger

  alias Raxol.AgentClientProtocol.Connection.{Dispatch, Link, Turns, Wire}
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.{Router, Telemetry}
  alias Raxol.AgentClientProtocol.Rpc
  alias Raxol.AgentClientProtocol.Rpc.{Notification, RequestId}
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification

  # `$/cancel_request` is protocol-layer and allowed before the handshake.
  @spec handle(Raxol.AgentClientProtocol.Connection.t(), Notification.t(), non_neg_integer()) ::
          {:noreply, Raxol.AgentClientProtocol.Connection.t()}
  def handle(state, %Notification{method: "$/cancel_request", params: params}, _rx_seq) do
    case CancelRequestNotification.from_json(params || %{}) do
      {:ok, %{request_id: cancel_id}} -> cancel_inbound(state, cancel_id)
      {:error, _} -> {:noreply, state}
    end
  end

  def handle(%{phase: phase} = state, %Notification{method: method}, _rx_seq)
      when phase != :initialized do
    Logger.debug("ACP: notification #{Rpc.printable(method)} dropped pre-handshake")
    {:noreply, state}
  end

  def handle(state, %Notification{method: "session/cancel", params: params}, rx_seq) do
    with {:ok, %{session_id: session_id}} <- CancelNotification.from_json(params || %{}) do
      case lookup_session(session_id) do
        [{spid, _} | _] ->
          GenServer.cast(spid, {:acp_session_cancel, rx_seq})

        [] ->
          Logger.debug("ACP: session/cancel for unknown session #{Rpc.loggable(session_id)}")
      end
    end

    {:noreply, state}
  end

  def handle(state, %Notification{method: method, params: params}, rx_seq) do
    case Router.decode(state.role, :notification, method, params) do
      {:error, _reason} ->
        Logger.debug("ACP: unknown/invalid notification #{Rpc.printable(method)} dropped")
        Telemetry.execute([:raxol, :acp, :unknown_notification], %{method: Rpc.printable(method)})
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
    ctx = %{Dispatch.ctx(state) | delivery_stamp: stamp}

    case Dispatch.start(state, dispatchable, ctx, state.notif_sup) do
      {:error, reason} ->
        shed(state, method, "notification pool full (#{inspect(reason)})")

      {:ok, task} ->
        {:noreply,
         %{
           state
           | task_index: Map.put(state.task_index, task.ref, {:notification, method})
         }}
    end
  end

  # A finished handler's result can still sit behind queued frames; count those
  # as done before deciding the pool is full.
  defp shed(state, method, why) do
    Logger.warning("ACP: notification #{Rpc.printable(method)} dropped: #{why}")
    Telemetry.execute([:raxol, :acp, :notification_shed], %{method: Rpc.printable(method)})
    {:noreply, state}
  end

  # Marks the entry cancelled first, then stops its task or tells its adopter.
  # The cancelled request is still answered, as the schema requires: an
  # undelegated one at once with -32800; a delegated one by its adopter, which
  # is told so it can wind down and reply (Session answers `cancelled`).
  defp cancel_inbound(state, cancel_id) do
    case Map.get(state.pending_in, cancel_id) do
      nil ->
        Logger.debug(
          "ACP: $/cancel_request for unknown/finished id #{RequestId.display(cancel_id)}"
        )

        {:noreply, state}

      # A repeated cancel for the same id changes nothing.
      %{cancelled?: true} ->
        {:noreply, state}

      %{adopter: {apid, _mon}, reply_ref: rref} = entry ->
        send(apid, {:acp_reply_cancelled, rref})

        timer =
          if state.cancel_reply_timeout_ms != :infinity,
            do:
              Process.send_after(
                self(),
                {:cancel_reply_timeout, cancel_id, rref},
                state.cancel_reply_timeout_ms
              )

        {:noreply,
         put_in(state.pending_in[cancel_id], %{entry | cancelled?: true, cancel_timer: timer})}

      entry ->
        if entry.task_pid, do: Task.Supervisor.terminate_child(state.task_sup, entry.task_pid)

        state
        |> Link.drop_pending_in(cancel_id, entry)
        |> Map.update!(:task_index, &Map.delete(&1, entry.task_ref))
        |> Link.emit(Wire.response(cancel_id, {:error, Error.request_cancelled()}))
    end
  end

  defp lookup_session(session_id) do
    registry = Raxol.AgentClientProtocol.Session.registry()

    case Process.whereis(registry) do
      nil -> []
      _pid -> Registry.lookup(registry, {self(), session_id})
    end
  end
end

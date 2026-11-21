defmodule Raxol.AgentClientProtocol.Connection.Link do
  @moduledoc false
  # Transport I/O, outcome delivery and teardown shared by the Connection's
  # inbound and outbound paths.

  require Logger

  alias Raxol.AgentClientProtocol.Connection.{Turns, Wire}
  alias Raxol.AgentClientProtocol.Rpc.{Notification, RequestId}

  @type state :: Raxol.AgentClientProtocol.Connection.t()
  @type reply_to :: {:call, GenServer.from()} | {:owner, pid(), term()}

  @spec push(state(), map()) :: {:ok, state()} | {:down, term()}
  def push(state, frame) do
    case state.transport_mod.send_message(state.transport_state, frame) do
      {:ok, ts} -> {:ok, %{state | transport_state: ts}}
      {:error, reason} -> {:down, reason}
    end
  end

  # Sends `frame`; a transport failure stops the Connection.
  @spec emit(state(), map()) :: {:noreply, state()} | {:stop, :normal, state()}
  def emit(state, frame) do
    case push(state, frame) do
      {:ok, st} -> {:noreply, st}
      {:down, _reason} -> {:stop, :normal, down(state)}
    end
  end

  @spec deliver(reply_to(), term()) :: :ok
  def deliver({:call, from}, outcome), do: GenServer.reply(from, outcome)

  def deliver({:owner, pid, tag}, outcome) do
    send(pid, {:acp_result, tag, outcome})
    :ok
  end

  # Best-effort `$/cancel_request`; a send failure is only logged.
  @spec cancel_notify(state(), RequestId.t()) :: :ok
  def cancel_notify(state, id) do
    frame =
      Wire.frame(Notification.new("$/cancel_request", %{"requestId" => RequestId.to_json(id)}))

    case state.transport_mod.send_message(state.transport_state, frame) do
      {:ok, _ts} ->
        :ok

      {:error, reason} ->
        Logger.debug("ACP: best-effort $/cancel_request failed: #{inspect(reason)}")
    end
  end

  @spec drop_pending_in(state(), RequestId.t(), map()) :: state()
  def drop_pending_in(state, id, entry) do
    demonitor_adopter(entry)

    %{
      state
      | pending_in: Map.delete(state.pending_in, id),
        reply_refs: Map.delete(state.reply_refs, entry.reply_ref)
    }
  end

  @spec demonitor_adopter(map()) :: :ok
  def demonitor_adopter(%{adopter: {_pid, mon}}) do
    Process.demonitor(mon, [:flush])
    :ok
  end

  def demonitor_adopter(_entry), do: :ok

  # The single idempotent teardown: fail every pending outbound request with
  # `:connection_closed`, kill undelegated inbound tasks, clear all tables.
  @spec down(state()) :: state()
  def down(%{phase: :closed} = state), do: state

  def down(state) do
    Enum.each(state.pending_out, fn {_id, %{reply_to: rt, timer_ref: timer}} ->
      if timer, do: Process.cancel_timer(timer)
      deliver(rt, {:error, :connection_closed})
    end)

    Enum.each(state.pending_in, fn {_id, entry} -> stop_inbound(state, entry) end)

    if state.transport_monitor, do: Process.demonitor(state.transport_monitor, [:flush])
    Enum.each(state.expired, fn {mon, _rref} -> Process.demonitor(mon, [:flush]) end)

    Turns.reset(%{
      state
      | pending_out: %{},
        out_tags: %{},
        pending_in: %{},
        task_index: %{},
        notif_tasks: 0,
        reply_refs: %{},
        expired: %{},
        phase: :closed
    })
  end

  defp stop_inbound(_state, %{adopter: {_apid, mon}}), do: Process.demonitor(mon, [:flush])
  defp stop_inbound(_state, %{task_pid: nil}), do: :ok

  defp stop_inbound(state, %{task_pid: pid}),
    do: Task.Supervisor.terminate_child(state.task_sup, pid)
end

defmodule Raxol.AgentClientProtocol.Connection.Outbound do
  @moduledoc false
  # Outbound requests and notifications, their timeouts, and correlation of
  # the peer's responses. The Connection is the single timeout authority: every
  # `pending_out` entry leaves via exactly one of response, timeout,
  # `cancel_request/2`, or teardown.

  require Logger

  alias Raxol.AgentClientProtocol.Connection.{Link, Turns, Wire}
  alias Raxol.AgentClientProtocol.Rpc.{Notification, Request, RequestId}
  alias Raxol.AgentClientProtocol.Telemetry

  @type state :: map()
  @type gate_error :: :connection_closed | :not_initialized

  @spec gate(state(), String.t()) :: :ok | {:error, gate_error()}
  def gate(%{phase: phase}, _method) when phase in [:booting, :closed],
    do: {:error, :connection_closed}

  def gate(%{phase: :initialized}, _method), do: :ok
  def gate(_state, "initialize"), do: :ok
  def gate(_state, _method), do: {:error, :not_initialized}

  # Returns `{:parked, state}` when the request is pending (the caller waits for
  # its outcome) or `{:answered, answer, state}` when it was refused now.
  @spec submit(state(), String.t(), term(), pos_integer() | :infinity, Link.reply_to()) ::
          {:parked, state()} | {:answered, {:error, term()}, state()}
  def submit(state, method, params, timeout_ms, reply_to) do
    with :ok <- gate(state, method),
         {:ok, wire_params} <- Wire.to_wire(params) do
      state
      |> stash_own_caps(method, params)
      |> send_request(method, params, wire_params, timeout_ms, reply_to)
    else
      {:error, reason} -> {:answered, {:error, reason}, state}
    end
  end

  defp send_request(state, method, params, wire_params, timeout_ms, reply_to) do
    id = state.next_out_id
    state = %{state | next_out_id: id + 1}

    # On a send failure nothing is pended; the consumed id leaves a harmless gap.
    case state.transport_mod.send_message(
           state.transport_state,
           Wire.frame(Request.new(id, method, wire_params))
         ) do
      {:error, reason} ->
        {:answered, {:error, {:transport, reason}}, state}

      {:ok, ts} ->
        pending = %{reply_to: reply_to, method: method, timer_ref: arm_timer(id, timeout_ms)}

        state = %{
          state
          | transport_state: ts,
            pending_out: Map.put(state.pending_out, id, pending),
            out_tags: add_tag(state.out_tags, reply_to, id)
        }

        {:parked, Turns.maybe_open(state, method, reply_to, params, id)}
    end
  end

  @spec notify(state(), String.t(), term()) ::
          {:reply, :ok | {:error, term()}, state()} | {:stop, :normal, {:error, term()}, state()}
  def notify(state, method, params) do
    with :ok <- gate(state, method),
         {:ok, wire_params} <- Wire.to_wire(params),
         {:ok, st} <- Link.push(state, Wire.frame(Notification.new(method, wire_params))) do
      {:reply, :ok, st}
    else
      {:down, reason} -> {:stop, :normal, {:error, {:transport, reason}}, Link.down(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Pops the entry silently: a cancelled request delivers nothing.
  @spec cancel(state(), pid(), term()) :: state()
  def cancel(state, owner_pid, tag) do
    case Map.pop(state.out_tags, {owner_pid, tag}) do
      {nil, _} ->
        state

      {id, out_tags} ->
        {entry, pending_out} = Map.pop(state.pending_out, id)
        if entry && entry.timer_ref, do: Process.cancel_timer(entry.timer_ref)
        Link.cancel_notify(state, id)
        Turns.pop_silent(%{state | pending_out: pending_out, out_tags: out_tags}, id)
    end
  end

  @spec timeout(state(), RequestId.t()) :: state()
  def timeout(state, id) do
    case Map.pop(state.pending_out, id) do
      {nil, _} ->
        state

      {%{reply_to: rt}, pending_out} ->
        state = Turns.close(state, id)
        Link.deliver(rt, {:error, :timeout})
        Link.cancel_notify(state, id)
        %{state | pending_out: pending_out, out_tags: drop_tag(state.out_tags, rt)}
    end
  end

  @spec response(state(), term()) :: state()
  def response(state, resp) do
    id = elem(resp, 1)

    case Map.pop(state.pending_out, id) do
      {nil, _} ->
        Logger.warning("ACP: late/unknown response id #{RequestId.display(id)} dropped")
        Telemetry.execute([:raxol, :acp, :late_response], %{id: RequestId.display(id)})
        state

      {%{reply_to: rt, method: method, timer_ref: timer}, pending_out} ->
        if timer, do: Process.cancel_timer(timer)
        state = Turns.close(state, id)
        outcome = Wire.decode_result(resp, method)
        Link.deliver(rt, outcome)

        %{state | pending_out: pending_out, out_tags: drop_tag(state.out_tags, rt)}
        |> client_initialized(method, outcome)
    end
  end

  # The client's `caps` snapshot is its own advertised capabilities, which only
  # appear in the outbound `initialize` request, so they are stashed at submit
  # and committed when the response arrives.
  defp stash_own_caps(%{role: :client} = state, "initialize", %{client_capabilities: caps}),
    do: %{state | own_caps: caps}

  defp stash_own_caps(%{role: :client} = state, "initialize", _params),
    do: %{state | own_caps: nil}

  defp stash_own_caps(state, _method, _params), do: state

  defp client_initialized(
         %{role: :client, phase: :uninitialized} = state,
         "initialize",
         {:ok, %_{}}
       ),
       do: %{state | phase: :initialized, caps: state.own_caps}

  defp client_initialized(state, _method, _outcome), do: state

  defp arm_timer(_id, :infinity), do: nil

  defp arm_timer(id, timeout_ms) when is_integer(timeout_ms),
    do: Process.send_after(self(), {:outbound_timeout, id}, timeout_ms)

  defp add_tag(out_tags, {:owner, pid, tag}, id), do: Map.put(out_tags, {pid, tag}, id)
  defp add_tag(out_tags, {:call, _from}, _id), do: out_tags

  defp drop_tag(out_tags, {:owner, pid, tag}), do: Map.delete(out_tags, {pid, tag})
  defp drop_tag(out_tags, {:call, _from}), do: out_tags
end

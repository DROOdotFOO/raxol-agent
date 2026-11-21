defmodule Raxol.AgentClientProtocol.Connection.Inbound do
  @moduledoc false
  # Inbound frame classification, request dispatch, and the reply obligations
  # handler tasks (or their adopters) discharge.
  #
  # At most one response frame is sent per inbound id: exactly one, unless the
  # peer cancelled it with `$/cancel_request` (then none). Malformed frames
  # never tear the connection down.

  require Logger

  alias Raxol.AgentClientProtocol.{Capabilities, Error, Router, Telemetry}
  alias Raxol.AgentClientProtocol.Connection.{Dispatch, Link, Notifications, Outbound, Wire}
  alias Raxol.AgentClientProtocol.Rpc
  alias Raxol.AgentClientProtocol.Rpc.{Notification, Request, RequestId, Response}

  @type state :: Raxol.AgentClientProtocol.Connection.t()
  @type result :: {:noreply, state()} | {:stop, :normal, state()}

  # -- Classification ---------------------------------------------------------

  @spec message(state(), term(), non_neg_integer()) :: result()
  def message(state, frame, _rx_seq) when is_list(frame), do: invalid_request(state, nil)

  def message(state, frame, rx_seq) when is_map(frame) do
    cond do
      Map.has_key?(frame, "id") and Map.has_key?(frame, "method") ->
        decode_and(state, frame, &Request.from_json/1, &request(&1, &2, rx_seq))

      Map.has_key?(frame, "id") and
          (Map.has_key?(frame, "result") or Map.has_key?(frame, "error")) ->
        response(state, frame)

      Map.has_key?(frame, "method") ->
        decode_and(state, frame, &Notification.from_json/1, &Notifications.handle(&1, &2, rx_seq))

      true ->
        malformed(state, frame)
    end
  end

  def message(state, _frame, _rx_seq), do: {:noreply, state}

  # A JSON array arriving from a byte transport is a batch (-32600); any other
  # decode failure is a parse error (-32700).
  @spec decode_error(state(), term()) :: result()
  def decode_error(state, {:not_an_object, list}) when is_list(list) do
    Telemetry.execute([:raxol, :acp, :invalid_request_frame], %{reason: :batch_array})
    invalid_request(state, nil)
  end

  def decode_error(state, reason) do
    Telemetry.execute([:raxol, :acp, :parse_error], %{reason: reason_tag(reason)})
    Link.emit(state, Wire.response(nil, {:error, Error.parse_error()}))
  end

  # Telemetry gets the kind of decode failure, never the peer's raw bytes.
  defp reason_tag(%{__exception__: true, __struct__: mod}), do: mod
  defp reason_tag({tag, n}) when is_atom(tag) and is_integer(n), do: {tag, n}
  defp reason_tag(tag) when is_atom(tag), do: tag
  defp reason_tag(_other), do: :unknown

  defp decode_and(state, frame, decode, handle) do
    case decode.(frame) do
      {:ok, decoded} -> handle.(state, decoded)
      {:error, _} -> malformed(state, frame)
    end
  end

  # A response that fails to decode is dropped, never answered: answering it
  # could cross-correlate with one of the peer's own pending requests.
  defp response(state, frame) do
    case Response.from_json(frame) do
      {:ok, resp} ->
        {:noreply, Outbound.response(state, resp)}

      {:error, _reason} ->
        id = Map.get(frame, "id")
        Logger.warning("ACP: malformed response frame dropped (id #{Rpc.loggable(id)})")
        Telemetry.execute([:raxol, :acp, :malformed_response], %{id: Rpc.loggable(id)})
        {:noreply, state}
    end
  end

  defp malformed(state, %{"id" => raw}), do: invalid_request(state, valid_id(raw))
  defp malformed(state, _frame), do: invalid_request(state, nil)

  defp valid_id(raw), do: if(RequestId.valid?(raw), do: RequestId.from_json(raw))

  defp invalid_request(state, id),
    do: Link.emit(state, Wire.response(id, {:error, Error.invalid_request()}))

  # -- Requests ---------------------------------------------------------------

  defp request(state, %Request{} = req, rx_seq) do
    case admit(state, req) do
      :accept -> decode_request(state, req, rx_seq)
      :drop -> {:noreply, state}
      {:reject, frame} -> Link.emit(state, frame)
    end
  end

  # Ordered admission checks; the first hit wins. The capability gate runs
  # before decode so -32601 beats -32602.
  defp admit(state, %Request{id: id, method: method} = req) do
    cond do
      rejection = handshake_rejection(state.phase, req) ->
        {:reject, rejection}

      id == nil ->
        Logger.warning(
          "ACP: inbound request with null id (method #{Rpc.printable(method)}) rejected -32600"
        )

        {:reject, Wire.response(nil, {:error, Error.invalid_request()})}

      Map.has_key?(state.pending_in, id) ->
        Telemetry.execute([:raxol, :acp, :duplicate_inflight_id], %{id: RequestId.display(id)})
        Logger.warning("ACP: duplicate in-flight request id #{RequestId.display(id)} dropped")
        :drop

      # Flood guard: over `max_in` concurrent requests are shed, never recorded.
      map_size(state.pending_in) >= state.max_in ->
        {:reject,
         shed(id, method, "#{state.max_in} concurrent inbound already in flight", %{
           "reason" => "too many concurrent inbound requests",
           "limit" => state.max_in
         })}

      not Capabilities.negotiated?(state.caps, method) ->
        {:reject, Wire.error(id, Error.method_not_found(), method)}

      true ->
        :accept
    end
  end

  defp handshake_rejection(:uninitialized, %Request{method: method, id: id})
       when method != "initialize" do
    Wire.error(id, Error.invalid_request(), %{
      "method" => method,
      "reason" => "initialize required"
    })
  end

  defp handshake_rejection(:initialized, %Request{method: "initialize", id: id}),
    do: Wire.error(id, Error.invalid_request(), %{"reason" => "already initialized"})

  defp handshake_rejection(_phase, _req), do: nil

  defp shed(id, method, why, data) do
    Telemetry.execute([:raxol, :acp, :inbound_shed], %{
      id: RequestId.display(id),
      method: Rpc.printable(method)
    })

    Logger.warning(
      "ACP: inbound request #{Rpc.printable(method)} (id #{RequestId.display(id)}) shed -32603: #{why}"
    )

    Wire.error(id, Error.new(Error.internal_error_code(), "Server busy"), data)
  end

  defp decode_request(state, %Request{id: id, method: method, params: params}, rx_seq) do
    case Router.decode(state.role, :request, method, params) do
      {:error, :method_not_found} ->
        Link.emit(state, Wire.error(id, Error.method_not_found(), method))

      {:error, reason} ->
        Link.emit(state, Wire.error(id, Error.invalid_params(), inspect(reason)))

      {:ok, dispatchable} ->
        spawn_request(state, id, method, dispatchable, rx_seq)
    end
  end

  defp spawn_request(state, id, method, dispatchable, rx_seq) do
    reply_ref = make_ref()
    ctx = %{Dispatch.ctx(state) | reply_ref: reply_ref, rx_seq: rx_seq}

    # `max_in` sheds first; a saturated task supervisor is a backstop.
    case Dispatch.start(state, dispatchable, ctx) do
      {:error, reason} ->
        frame =
          shed(id, method, "dispatch task_sup saturated (#{inspect(reason)})", %{
            "reason" => "dispatch capacity exhausted"
          })

        Link.emit(state, frame)

      {:ok, task} ->
        entry = %{
          task_ref: task.ref,
          task_pid: task.pid,
          method: method,
          cancelled?: false,
          reply_ref: reply_ref,
          adopter: nil
        }

        {:noreply,
         %{
           state
           | pending_in: Map.put(state.pending_in, id, entry),
             reply_refs: Map.put(state.reply_refs, reply_ref, id),
             task_index: Map.put(state.task_index, task.ref, {:request, id})
         }}
    end
  end

  # -- Task results and crashes -----------------------------------------------

  @spec task_result(state(), reference(), term()) :: result()
  def task_result(state, ref, result) do
    case Map.get(state.task_index, ref) do
      nil ->
        {:noreply, state}

      tag ->
        Process.demonitor(ref, [:flush])
        state = %{state | task_index: Map.delete(state.task_index, ref)}

        case tag do
          {:request, id} -> request_result(state, id, result)
          {:notification, _method} -> {:noreply, state}
        end
    end
  end

  defp request_result(state, id, result) do
    case Map.get(state.pending_in, id) do
      nil ->
        {:noreply, state}

      # Cancelled after delegation: the adopter still replies (and the reply is
      # suppressed), so keep the entry for it.
      %{cancelled?: true, adopter: {_pid, _mon}} = entry when result == :deferred ->
        {:noreply, put_in(state.pending_in[id], %{entry | task_ref: nil, task_pid: nil})}

      %{cancelled?: true} = entry ->
        {:noreply, Link.drop_pending_in(state, id, entry)}

      entry ->
        finish(state, id, entry, result)
    end
  end

  # `:deferred` is legal only once the reply was delegated.
  defp finish(state, id, %{adopter: nil} = entry, :deferred) do
    Logger.error(
      "ACP: handler returned :deferred without delegate_reply (id #{RequestId.display(id)})"
    )

    state |> Link.drop_pending_in(id, entry) |> internal_error(id)
  end

  defp finish(state, id, entry, :deferred) do
    {:noreply,
     %{state | pending_in: Map.put(state.pending_in, id, %{entry | task_ref: nil, task_pid: nil})}}
  end

  defp finish(state, id, entry, result) do
    state
    |> Link.drop_pending_in(id, entry)
    |> send_response(
      id,
      entry,
      checked(state, entry, result),
      &{:noreply, &1},
      &{:stop, :normal, &1}
    )
  end

  # A malformed result from a handler or an adopter is answered -32603 rather
  # than crashing the Connection.
  defp checked(state, entry, result) do
    case Wire.handler_result(result, entry.method) do
      {:ok, response} ->
        response

      :malformed ->
        Logger.error(
          "ACP: handler #{inspect(state.handler)} returned malformed value for " <>
            "#{Rpc.printable(entry.method)}: #{inspect(result, limit: 20)}"
        )

        {:error, Error.internal_error()}
    end
  end

  defp send_response(state, id, entry, response, on_ok, on_down) do
    case Link.push(state, Wire.response(id, response)) do
      {:ok, st} -> on_ok.(agent_initialized(st, entry, response))
      {:down, _reason} -> on_down.(Link.down(state))
    end
  end

  @spec down(state(), reference(), term()) :: result()
  def down(state, ref, reason) do
    case Map.pop(state.task_index, ref) do
      {nil, _} ->
        adopter_down(state, ref)

      {{:notification, method}, task_index} ->
        notification_crash(%{state | task_index: task_index}, method, reason)

      {{:request, id}, task_index} ->
        request_crash(%{state | task_index: task_index}, id, reason)
    end
  end

  defp notification_crash(state, method, reason) do
    Logger.error(
      "ACP: notification handler crashed (#{Rpc.printable(method)}): #{inspect(reason)}"
    )

    Telemetry.execute([:raxol, :acp, :handler_crash], %{
      kind: :notification,
      method: Rpc.printable(method)
    })

    {:noreply, state}
  end

  defp request_crash(state, id, reason) do
    case Map.get(state.pending_in, id) do
      nil ->
        {:noreply, state}

      # The adopter owns the reply now; it answers (or its DOWN does). The
      # entry holds an inbound slot until then.
      %{adopter: {_pid, _mon}} = entry ->
        if reason != :normal, do: report_crash(entry, id, reason)
        entry = %{entry | task_ref: nil, task_pid: nil}
        {:noreply, %{state | pending_in: Map.put(state.pending_in, id, entry)}}

      %{cancelled?: cancelled?} = entry when cancelled? or reason == :normal ->
        {:noreply, Link.drop_pending_in(state, id, entry)}

      entry ->
        report_crash(entry, id, reason)
        state |> Link.drop_pending_in(id, entry) |> internal_error(id)
    end
  end

  defp report_crash(entry, id, reason) do
    Logger.error(
      "ACP: request handler crashed (#{Rpc.printable(entry.method)}, id #{RequestId.display(id)}): " <>
        inspect(reason)
    )

    Telemetry.execute([:raxol, :acp, :handler_crash], %{
      kind: :request,
      method: Rpc.printable(entry.method)
    })
  end

  defp adopter_down(state, mon_ref) do
    case find_adopter(state.pending_in, mon_ref) do
      nil ->
        {:noreply, state}

      {id, %{cancelled?: true} = entry} ->
        {:noreply, Link.drop_pending_in(state, id, entry)}

      {id, entry} ->
        Logger.error("ACP: reply adopter died for id #{RequestId.display(id)} — emitting -32603")
        state |> Link.drop_pending_in(id, entry) |> internal_error(id)
    end
  end

  defp find_adopter(pending_in, mon_ref) do
    Enum.find_value(pending_in, fn
      {id, %{adopter: {_pid, ^mon_ref}} = entry} -> {id, entry}
      _ -> nil
    end)
  end

  defp internal_error(state, id),
    do: Link.emit(state, Wire.response(id, {:error, Error.internal_error()}))

  # -- Delegated replies ------------------------------------------------------

  @spec delegate(state(), reference(), pid()) ::
          {:ok, state()} | {:error, :unknown_ref | :cancelled}
  def delegate(state, reply_ref, adopter) do
    case Map.get(state.reply_refs, reply_ref) do
      nil ->
        {:error, :unknown_ref}

      id ->
        case Map.fetch!(state.pending_in, id) do
          # The peer already cancelled it; the would-be adopter must not run it.
          %{cancelled?: true} ->
            {:error, :cancelled}

          entry ->
            entry = %{entry | adopter: {adopter, Process.monitor(adopter)}}
            {:ok, %{state | pending_in: Map.put(state.pending_in, id, entry)}}
        end
    end
  end

  # An unknown or already-consumed `reply_ref` is a suppressed no-op.
  @spec reply(state(), reference(), Wire.result()) ::
          {:reply, :ok, state()} | {:stop, :normal, :ok, state()}
  def reply(state, reply_ref, result) do
    case Map.pop(state.reply_refs, reply_ref) do
      {nil, _} ->
        Telemetry.execute([:raxol, :acp, :dup_reply], %{reply_ref: reply_ref})
        {:reply, :ok, state}

      {id, reply_refs} ->
        {entry, pending_in} = Map.pop(state.pending_in, id)
        Link.demonitor_adopter(entry)
        state = %{state | reply_refs: reply_refs, pending_in: pending_in}

        if entry.cancelled?,
          do: {:reply, :ok, state},
          else:
            send_response(
              state,
              id,
              entry,
              checked(state, entry, result),
              &{:reply, :ok, &1},
              &{:stop, :normal, :ok, &1}
            )
    end
  end

  # The agent's `caps` snapshot is the capabilities in the `initialize`
  # response it sent; written once.
  defp agent_initialized(
         %{role: :agent, phase: :uninitialized} = state,
         %{method: "initialize"},
         {:ok, response}
       ) do
    %{state | phase: :initialized, caps: agent_caps(response)}
  end

  defp agent_initialized(state, _entry, _response), do: state

  defp agent_caps(%{agent_capabilities: caps}), do: caps
  defp agent_caps(_other), do: nil
end

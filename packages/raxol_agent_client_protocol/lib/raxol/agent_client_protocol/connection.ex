defmodule Raxol.AgentClientProtocol.Connection do
  @moduledoc """
  One GenServer per peer link, in either role: JSON-RPC correlation and
  dispatch for ACP. `role` selects which `MethodTable` direction is inbound.

  The Connection never blocks (no self-calls, no waiting on tasks or the peer),
  never runs handler code in its own process (every inbound request or
  notification runs in a `Task.Supervisor.async_nolink` task), and never creates
  atoms from wire input.

    * Outbound: `async_request/6` is the primitive and `request/4` parks the
      caller on the same table. The Connection owns every timeout. Each pending
      request ends through exactly one of response, timeout, `cancel_request/2`
      or teardown.
    * Inbound: a handler crash answers `-32603`, echoing the id at its exact
      wire type. A notification crash is only logged. `$/cancel_request` and
      `session/cancel` are handled by the Connection itself; a cancelled
      request is still answered once (-32800, or its adopter's reply).
    * Delegated replies: `delegate_reply/3`, `reply/3` and a `:deferred` handler
      return let `Session` decide when the `session/prompt` response goes out,
      on the same FIFO lane as its updates.
    * Capability gate: checked before decode, so `-32601` beats `-32602`. It
      fails closed against the receiver's own negotiated capabilities.

  Pass the sibling supervisors either as `:parent_sup` (resolved via
  `which_children` after init) or directly as `:task_sup`/`:session_sup`.
  """

  use GenServer
  require Logger

  alias Raxol.AgentClientProtocol.Connection.{Inbound, Link, Outbound, Turns, TurnState}
  alias Raxol.AgentClientProtocol.Error

  # Concurrent inbound-request cap; excess requests are shed with -32603.
  @default_max_inbound 1_000

  # Concurrent notification-handler cap; excess notifications are dropped so
  # they cannot use up the task capacity requests need.
  @default_max_notification_tasks 500

  # After the peer closes its write side, the Connection stops once every
  # in-flight inbound request is answered, or after this bound.
  @default_close_drain_ms 300_000

  # How long an adopter told of a `$/cancel_request` may take to reply before
  # the request is answered -32800 and its inbound slot freed.
  # Longer than Session's 30s cancel backstop, so a Session answers first.
  @default_cancel_reply_timeout_ms 60_000

  defstruct role: :agent,
            transport_mod: nil,
            transport_state: nil,
            transport_ref: nil,
            transport_monitor: nil,
            phase: :booting,
            caps: nil,
            own_caps: nil,
            parent_sup: nil,
            session_sup: nil,
            rx_seq: 0,
            next_out_id: 1,
            pending_out: %{},
            out_tags: %{},
            pending_in: %{},
            reply_refs: %{},
            task_index: %{},
            handler: nil,
            handler_state: nil,
            task_sup: nil,
            max_in: @default_max_inbound,
            max_notification_tasks: @default_max_notification_tasks,
            notif_tasks: 0,
            close_drain_ms: @default_close_drain_ms,
            draining?: false,
            cancel_reply_timeout_ms: @default_cancel_reply_timeout_ms,
            timed_out_adopters: %{},
            turns: %{},
            turn_ids: %{},
            oot_seq: %{}

  @type role :: :agent | :client
  @type phase :: :booting | :uninitialized | :initialized | :closed

  @type t :: %__MODULE__{
          role: role(),
          transport_mod: module() | nil,
          transport_state: term(),
          transport_ref: pid() | nil,
          transport_monitor: reference() | nil,
          phase: phase(),
          caps: term(),
          own_caps: term(),
          parent_sup: GenServer.server() | nil,
          session_sup: pid() | nil,
          rx_seq: non_neg_integer(),
          next_out_id: pos_integer(),
          pending_out: map(),
          out_tags: map(),
          pending_in: map(),
          reply_refs: map(),
          task_index: map(),
          handler: module() | nil,
          handler_state: term(),
          task_sup: GenServer.server() | nil,
          max_in: pos_integer(),
          max_notification_tasks: pos_integer(),
          notif_tasks: non_neg_integer(),
          close_drain_ms: pos_integer() | :infinity,
          draining?: boolean(),
          cancel_reply_timeout_ms: pos_integer() | :infinity,
          timed_out_adopters: %{reference() => reference()},
          turns: %{String.t() => TurnState.t()},
          turn_ids: map(),
          oot_seq: %{String.t() => non_neg_integer()}
        }

  @typedoc "Outcome delivered for an accepted outbound submission."
  @type outcome ::
          {:ok, struct()}
          | {:ok, {:ext, map()}}
          | {:error, Error.t() | :timeout | :connection_closed | {:result_decode, term()}}

  @type params :: struct() | map() | nil

  # Every public function raises when called from inside the Connection itself.

  @doc """
  Starts a Connection. Options: `:role`, `:transport` (`{mod, handle}`),
  `:handler`, `:handler_arg`, `:max_inbound` (a positive integer, default
  #{@default_max_inbound}; anything else stops with
  `{:invalid_option, :max_inbound, value}`), `:max_notification_tasks` (likewise,
  default #{@default_max_notification_tasks}), `:close_drain_ms` (how long, after the
  peer closes, in-flight requests may still be answered; a positive integer or
  `:infinity`, default #{@default_close_drain_ms}), `:cancel_reply_timeout_ms` (how long
  an adopter told of a cancel may take to reply, likewise, default
  #{@default_cancel_reply_timeout_ms}), and either `:parent_sup` or
  `:task_sup`/`:session_sup`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Submits a request without blocking. Returns `:ok` once the transport accepts
  the frame, then sends exactly one `{:acp_result, tag, outcome}` to `owner`,
  or none if `owner` cancels first with `cancel_request/2`.
  """
  @spec async_request(pid(), String.t(), params(), pid(), term(), pos_integer() | :infinity) ::
          :ok | {:error, :not_initialized | :connection_closed | {:transport, term()}}
  def async_request(conn, method, params, owner, tag, timeout_ms)
      when is_pid(conn) and is_binary(method) and is_pid(owner) do
    call(conn, {:async_request, method, params, owner, tag, timeout_ms})
  end

  @doc """
  Sends a request and waits for its outcome. The protocol timeout is
  `timeout_ms`, enforced by the Connection; the call itself never times out.
  """
  @spec request(pid(), String.t(), params(), pos_integer()) ::
          {:ok, struct()} | {:ok, {:ext, map()}} | {:error, term()}
  def request(conn, method, params, timeout_ms)
      when is_pid(conn) and is_binary(method) and is_integer(timeout_ms) do
    call(conn, {:request, method, params, timeout_ms}, :infinity)
  end

  @doc "Sends a notification. A call, for per-sender FIFO and backpressure."
  @spec notify(pid(), String.t(), params()) :: :ok | {:error, term()}
  def notify(conn, method, params) when is_pid(conn) and is_binary(method) do
    call(conn, {:notify, method, params})
  end

  @doc """
  Cancels the caller's pending `async_request/6` with `tag`: nothing is
  delivered and the peer gets a best-effort `$/cancel_request`. Unknown tags
  return `:ok`.
  """
  @spec cancel_request(pid(), term()) :: :ok
  def cancel_request(conn, tag) when is_pid(conn), do: call(conn, {:cancel_request, tag})

  @doc """
  Transfers an inbound request's reply obligation to `adopter`, which the
  Connection then monitors. Must return before the handler returns `:deferred`.
  Returns `{:error, :unknown_ref}` once the peer has cancelled (and the
  Connection answered) an undelegated request, and `{:error, :cancelled}` for a
  request already delegated and cancelled. If the peer cancels after delegation,
  the adopter receives `{:acp_reply_cancelled, reply_ref}` and should reply (its
  reply is sent) or exit (-32800 is sent); after `:cancel_reply_timeout_ms` the
  request is answered -32800 and later replies are ignored.
  """
  @spec delegate_reply(pid(), reference(), pid()) :: :ok | {:error, :unknown_ref | :cancelled}
  def delegate_reply(conn, reply_ref, adopter)
      when is_pid(conn) and is_reference(reply_ref) and is_pid(adopter) do
    call(conn, {:delegate_reply, reply_ref, adopter})
  end

  @doc """
  Discharges a delegated reply. An unknown or consumed `reply_ref` is a no-op
  that emits `[:raxol, :acp, :dup_reply]`. A reply after a cancel is sent, unless
  `:cancel_reply_timeout_ms` already answered -32800, in which case it is a quiet
  no-op. A malformed result is answered `-32603`; extension methods may reply
  with a plain map.
  """
  @spec reply(pid(), reference(), {:ok, map()} | {:error, Error.t()}) :: :ok
  def reply(conn, reply_ref, result_or_error) when is_pid(conn) and is_reference(reply_ref) do
    call(conn, {:reply, reply_ref, result_or_error})
  end

  @doc "Closes gracefully: fails pending requests, closes the transport, stops `:normal`."
  @spec close(pid()) :: :ok
  def close(conn) when is_pid(conn), do: call(conn, :close)

  @doc """
  Returns the current delivery watermark for `session_id`. Serialized with the
  point that assigns ordinals, so a caller that subscribes and then calls this
  knows every later stamp reaches it. `turn: nil` means no open turn. Sessions
  outside the out-of-turn tracking cap (`Connection.Turns.max_oot_sessions/0`
  sessions, ids of at most 256 bytes) report `0`.
  """
  @spec update_watermark(pid(), String.t()) ::
          {:ok, %{turn: reference() | nil, ordinal: non_neg_integer()}}
  def update_watermark(conn, session_id) when is_pid(conn) and is_binary(session_id) do
    call(conn, {:update_watermark, session_id})
  end

  defp call(conn, msg, timeout \\ 5_000) do
    if conn == self() do
      raise ArgumentError, "Connection API called with conn == self(): forbidden re-entrant cycle"
    end

    GenServer.call(conn, msg, timeout)
  end

  # -- Lifecycle --------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = Keyword.fetch!(opts, :handler)

    with {:ok, max_in} <- positive_option(opts, :max_inbound, @default_max_inbound),
         {:ok, max_notification_tasks} <-
           positive_option(opts, :max_notification_tasks, @default_max_notification_tasks),
         {:ok, close_drain_ms} <- timeout_option(opts, :close_drain_ms, @default_close_drain_ms),
         {:ok, cancel_reply_timeout_ms} <-
           timeout_option(opts, :cancel_reply_timeout_ms, @default_cancel_reply_timeout_ms),
         {:ok, handler_state} <- init_handler(handler, Keyword.get(opts, :handler_arg)) do
      {mod, handle} = Keyword.fetch!(opts, :transport)

      state = %__MODULE__{
        role: Keyword.get(opts, :role, :agent),
        transport_mod: mod,
        transport_state: handle,
        parent_sup: Keyword.get(opts, :parent_sup),
        session_sup: Keyword.get(opts, :session_sup),
        task_sup: Keyword.get(opts, :task_sup),
        handler: handler,
        handler_state: handler_state,
        max_in: max_in,
        max_notification_tasks: max_notification_tasks,
        close_drain_ms: close_drain_ms,
        cancel_reply_timeout_ms: cancel_reply_timeout_ms
      }

      {:ok, state, {:continue, :boot}}
    end
  end

  # A non-integer cap would compare greater than any count and silently
  # disable its guard, so it is refused.
  defp positive_option(opts, key, default), do: positive(key, Keyword.get(opts, key, default))

  defp positive(_key, n) when is_integer(n) and n > 0, do: {:ok, n}
  defp positive(key, other), do: {:stop, {:invalid_option, key, other}}

  defp timeout_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :infinity -> {:ok, :infinity}
      other -> positive(key, other)
    end
  end

  defp init_handler(handler, arg) do
    case handler.init(arg) do
      {:ok, handler_state} -> {:ok, handler_state}
      {:stop, reason} -> {:stop, reason}
      other -> {:stop, {:bad_handler_init, other}}
    end
  end

  # Sibling lookup happens here, not in init/1, to avoid a which_children deadlock.
  @impl GenServer
  def handle_continue(:boot, state) do
    {task_sup, session_sup} = resolve_siblings(state)
    carrier = carrier_pid(state.transport_state)

    if function_exported?(state.transport_mod, :set_owner, 2),
      do: state.transport_mod.set_owner(state.transport_state, self())

    {:noreply,
     %{
       state
       | task_sup: task_sup,
         session_sup: session_sup,
         transport_ref: carrier,
         transport_monitor: carrier && Process.monitor(carrier),
         phase: :uninitialized
     }}
  end

  defp resolve_siblings(%{parent_sup: nil} = state), do: {state.task_sup, state.session_sup}

  defp resolve_siblings(%{parent_sup: sup}) do
    children = Supervisor.which_children(sup)

    task_sup =
      Enum.find_value(children, fn {_id, pid, _type, mods} ->
        if is_pid(pid) and Task.Supervisor in mods, do: pid
      end)

    session_sup =
      Enum.find_value(children, fn {_id, pid, type, mods} ->
        if is_pid(pid) and pid != self() and type == :supervisor and Task.Supervisor not in mods,
          do: pid
      end)

    {task_sup, session_sup}
  end

  defp carrier_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp carrier_pid(_handle), do: nil

  @impl GenServer
  def terminate(_reason, state) do
    state = Link.down(state)
    if state.transport_mod, do: state.transport_mod.close(state.transport_state)
    :ok
  end

  # -- Callbacks --------------------------------------------------------------

  @impl GenServer
  def handle_call(msg, from, state), do: msg |> on_call(from, state) |> drain_check()

  @impl GenServer
  def handle_info(msg, state), do: msg |> on_info(state) |> drain_check()

  # While draining, the Connection stops as soon as nothing is in flight. Checked
  # here, after every callback, so no retirement path can be missed.
  defp drain_check({:noreply, %{draining?: true, pending_in: p} = st}) when map_size(p) == 0,
    do: {:stop, :normal, Link.down(st)}

  defp drain_check({:reply, reply, %{draining?: true, pending_in: p} = st}) when map_size(p) == 0,
    do: {:stop, :normal, reply, Link.down(st)}

  defp drain_check(result), do: result

  # -- Calls ------------------------------------------------------------------

  defp on_call({:request, method, params, timeout_ms}, from, state) do
    case Outbound.submit(state, method, params, timeout_ms, {:call, from}) do
      {:parked, st} -> {:noreply, st}
      {:answered, answer, st} -> {:reply, answer, st}
    end
  end

  defp on_call({:async_request, method, params, owner, tag, timeout_ms}, _from, state) do
    case Outbound.submit(state, method, params, timeout_ms, {:owner, owner, tag}) do
      {:parked, st} -> {:reply, :ok, st}
      {:answered, answer, st} -> {:reply, answer, st}
    end
  end

  defp on_call({:notify, method, params}, _from, state),
    do: Outbound.notify(state, method, params)

  defp on_call({:cancel_request, tag}, {owner_pid, _}, state),
    do: {:reply, :ok, Outbound.cancel(state, owner_pid, tag)}

  defp on_call({:update_watermark, session_id}, _from, state),
    do: {:reply, {:ok, Turns.watermark(state, session_id)}, state}

  defp on_call({:delegate_reply, reply_ref, adopter}, _from, state) do
    case Inbound.delegate(state, reply_ref, adopter) do
      {:ok, st} -> {:reply, :ok, st}
      error -> {:reply, error, state}
    end
  end

  defp on_call({:reply, reply_ref, result}, _from, state),
    do: Inbound.reply(state, reply_ref, result)

  defp on_call(:close, _from, state), do: {:stop, :normal, :ok, Link.down(state)}

  # -- Messages ---------------------------------------------------------------

  defp on_info({:outbound_timeout, id}, state), do: {:noreply, Outbound.timeout(state, id)}

  defp on_info({:cancel_reply_timeout, id, reply_ref}, state),
    do: Inbound.cancel_reply_timeout(state, id, reply_ref)

  defp on_info({:acp_transport, ref, _event}, %{transport_ref: current} = state)
       when ref != current do
    Logger.debug("ACP: dropping event from stale transport ref #{inspect(ref)}")
    {:noreply, state}
  end

  defp on_info({:acp_transport, _ref, {:message, frame}}, state) do
    rx_seq = state.rx_seq + 1
    Inbound.message(%{state | rx_seq: rx_seq}, frame, rx_seq)
  end

  # A peer that sends its requests and closes its write side still gets its
  # answers: the Connection drains (see `drain_check/1`) instead of stopping.
  defp on_info({:acp_transport, _ref, {:closed, reason}}, state) do
    if state.phase != :closed and map_size(state.pending_in) > 0 do
      if state.close_drain_ms != :infinity,
        do: Process.send_after(self(), {:acp_close_drained, reason}, state.close_drain_ms)

      {:noreply, %{state | draining?: true}}
    else
      {:stop, :normal, Link.down(state)}
    end
  end

  defp on_info({:acp_transport, _ref, {:decode_error, reason, _raw_line}}, state),
    do: Inbound.decode_error(state, reason)

  defp on_info({:acp_close_drained, _reason}, state), do: {:stop, :normal, Link.down(state)}

  defp on_info({ref, result}, state) when is_reference(ref),
    do: Inbound.task_result(state, ref, result)

  defp on_info({:DOWN, ref, :process, _pid, _reason}, %{transport_monitor: ref} = state),
    do: {:stop, :normal, Link.down(state)}

  defp on_info({:DOWN, ref, :process, _pid, reason}, state),
    do: Inbound.down(state, ref, reason)

  defp on_info(_msg, state), do: {:noreply, state}
end

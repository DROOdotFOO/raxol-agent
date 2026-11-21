defmodule Raxol.AgentClientProtocol.Connection.TurnState do
  @moduledoc """
  Per-session open-turn state on a client-role Connection.

  Opened when a `session/prompt` is submitted via `Connection.async_request/6`
  and closed by whichever of response, timeout, cancel or transport-down comes
  first. `token` is minted locally (`make_ref/0`), never derived from peer ids,
  so a replayed id cannot alias a stale turn's updates into a new one.
  """

  @enforce_keys [:token, :owner, :tag, :out_id]
  defstruct token: nil, owner: nil, tag: nil, out_id: nil, next_ordinal: 0

  @type t :: %__MODULE__{
          token: reference(),
          owner: pid(),
          tag: term(),
          out_id: term(),
          next_ordinal: non_neg_integer()
        }
end

defmodule Raxol.AgentClientProtocol.Connection.Turns do
  @moduledoc false
  # Turn bookkeeping over the Connection state's `turns` (session_id =>
  # TurnState), `turn_ids` (out_id => session_id) and `oot_seq` (session_id =>
  # out-of-turn update count; monotone while the connection is open, for at
  # most `max_oot_sessions/0` sessions).
  #
  # Only an async `session/prompt` (reply_to `{:owner, ...}`) opens a turn: a
  # sync caller is parked in `GenServer.call` and cannot receive deliveries, so
  # its session's updates are stamped out-of-turn.

  alias Raxol.AgentClientProtocol.Connection.TurnState
  alias Raxol.AgentClientProtocol.Delivery

  @max_oot_sessions 10_000

  @doc false
  @spec max_oot_sessions() :: 10_000
  def max_oot_sessions, do: @max_oot_sessions

  @type state :: %{
          :turns => %{String.t() => TurnState.t()},
          :turn_ids => %{term() => String.t()},
          :oot_seq => %{String.t() => non_neg_integer()},
          optional(atom()) => term()
        }

  @spec maybe_open(state(), String.t(), term(), term(), term()) :: state()
  def maybe_open(state, "session/prompt", {:owner, owner, tag}, params, id) do
    case prompt_session_id(params) do
      nil ->
        state

      session_id ->
        turn = %TurnState{token: make_ref(), owner: owner, tag: tag, out_id: id}
        state = close_replaced(state, session_id)

        %{
          state
          | turns: Map.put(state.turns, session_id, turn),
            turn_ids: Map.put(state.turn_ids, id, session_id)
        }
    end
  end

  def maybe_open(state, _method, _reply_to, _params, _id), do: state

  defp prompt_session_id(%{session_id: session_id}) when is_binary(session_id), do: session_id
  defp prompt_session_id(%{"sessionId" => session_id}) when is_binary(session_id), do: session_id
  defp prompt_session_id(_other), do: nil

  # A second prompt for a session replaces its open turn; the old owner gets
  # its `:acp_turn_end` first.
  defp close_replaced(state, session_id) do
    case Map.get(state.turns, session_id) do
      nil ->
        state

      %TurnState{} = old ->
        send(old.owner, {:acp_turn_end, old.tag, old.next_ordinal})

        %{
          state
          | turns: Map.delete(state.turns, session_id),
            turn_ids: Map.delete(state.turn_ids, old.out_id)
        }
    end
  end

  # Closes the turn for `out_id`, sending `{:acp_turn_end, tag, count}`. Called
  # just before the result is delivered, from the same process, so the owner
  # sees updates, then turn_end, then the result.
  @spec close(state(), term()) :: state()
  def close(state, out_id) do
    case Map.pop(state.turn_ids, out_id) do
      {nil, _} ->
        state

      {session_id, turn_ids} ->
        {turn, turns} = Map.pop(state.turns, session_id)
        if turn, do: send(turn.owner, {:acp_turn_end, turn.tag, turn.next_ordinal})
        %{state | turns: turns, turn_ids: turn_ids}
    end
  end

  # For `cancel_request/2`: a cancelled entry delivers nothing, not even turn_end.
  @spec pop_silent(state(), term()) :: state()
  def pop_silent(state, out_id) do
    case Map.pop(state.turn_ids, out_id) do
      {nil, _} ->
        state

      {session_id, turn_ids} ->
        %{state | turns: Map.delete(state.turns, session_id), turn_ids: turn_ids}
    end
  end

  # Stamps a `session/update` and, when its session has an open turn, delivers
  # `{:acp_turn_update, tag, ordinal, notif}` to the owner.
  @spec stamp_update(
          state(),
          %{:session_id => String.t(), optional(atom()) => term()},
          non_neg_integer()
        ) ::
          {Delivery.t(), state()}
  def stamp_update(state, %{session_id: session_id} = notif, rx_seq) do
    case Map.get(state.turns, session_id) do
      %TurnState{owner: owner, tag: tag, token: token, next_ordinal: n} ->
        send(owner, {:acp_turn_update, tag, n, notif})

        Delivery.emit(%{
          session: session_id,
          turn: token,
          decision: :emit,
          buffered: 0,
          ordinal: n
        })

        {Delivery.new(token, n, rx_seq), put_in(state.turns[session_id].next_ordinal, n + 1)}

      nil ->
        stamp_out_of_turn(state, session_id, rx_seq)
    end
  end

  # Out-of-turn counters are kept for at most @max_oot_sessions sessions, so a
  # peer inventing session ids cannot grow the map without bound. Updates for
  # sessions beyond the cap are stamped ordinal 0 and not tracked.
  defp stamp_out_of_turn(state, session_id, rx_seq) do
    case Map.fetch(state.oot_seq, session_id) do
      {:ok, ordinal} ->
        {Delivery.new(nil, ordinal, rx_seq),
         %{state | oot_seq: Map.put(state.oot_seq, session_id, ordinal + 1)}}

      :error when map_size(state.oot_seq) < @max_oot_sessions ->
        {Delivery.new(nil, 0, rx_seq), %{state | oot_seq: Map.put(state.oot_seq, session_id, 1)}}

      :error ->
        {Delivery.new(nil, 0, rx_seq), state}
    end
  end

  @spec watermark(state(), String.t()) :: %{turn: reference() | nil, ordinal: non_neg_integer()}
  def watermark(state, session_id) do
    case Map.get(state.turns, session_id) do
      %TurnState{token: token, next_ordinal: n} -> %{turn: token, ordinal: max(n - 1, 0)}
      nil -> %{turn: nil, ordinal: Map.get(state.oot_seq, session_id, 0)}
    end
  end

  @spec reset(state()) :: state()
  def reset(state), do: %{state | turns: %{}, turn_ids: %{}, oot_seq: %{}}
end

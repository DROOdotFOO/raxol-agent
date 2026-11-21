defmodule Raxol.AgentClientProtocol.Session.Emitter do
  @moduledoc """
  The seam through which a Session sends every `session/update` and turn
  boundary. `Emitter.Direct` (the default) just notifies the Connection;
  `Emitter.Journal` also appends to the session's durable journal.

  `session_state` is the `%Raxol.AgentClientProtocol.Session{}` struct.
  `turn_started/3` returns `{:error, :turn_in_flight}` when another connection
  holds the session's turn; the Session then replies busy. `rendered` in
  `turn_completed/3` is the same value sent as the prompt response.
  """

  @callback emit(session_state :: struct(), notification :: struct()) :: :ok
  @callback turn_started(
              session_state :: struct(),
              prompt_req :: term(),
              turn_id :: pos_integer()
            ) ::
              :ok | {:error, :turn_in_flight}
  @callback turn_completed(
              session_state :: struct(),
              rendered :: term(),
              turn_id :: pos_integer()
            ) ::
              :ok

  @doc "Optional. Called when the Session idle-reaps, to stop any durable process it owns."
  @callback reap(session_state :: struct()) :: :ok

  @doc """
  Optional. Called once per accepted steer with the accept `ref`
  (`%{turn_id, offset, client_msg_id}`) and the steer `request`.
  """
  @callback steer_accepted(session_state :: struct(), ref :: map(), request :: map()) :: :ok

  @optional_callbacks reap: 1, steer_accepted: 3
end

defmodule Raxol.AgentClientProtocol.Session.Emitter.Direct do
  @moduledoc """
  The default emitter: forwards updates to `Connection.notify/3`, on the same
  FIFO lane as the prompt reply. Keeps no journal.
  """

  @behaviour Raxol.AgentClientProtocol.Session.Emitter

  @impl true
  def emit(state, notification) do
    _ = state.conn_mod.notify(state.conn, "session/update", notification)
    :ok
  end

  @impl true
  def turn_started(_state, _req, _turn_id), do: :ok

  @impl true
  def turn_completed(_state, _rendered, _turn_id), do: :ok

  @impl true
  def reap(_state), do: :ok
end

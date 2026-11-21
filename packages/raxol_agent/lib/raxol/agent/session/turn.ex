defmodule Raxol.Agent.Session.Turn do
  @moduledoc false
  # The session's in-flight prompt turns (see "Agent turns" in
  # `Raxol.Agent.Session`). Each function takes and returns the session
  # state; `turns` is keyed by the caller's ref, `agent_refs` maps the ref the
  # agent sees back to it, and `monitors` maps caller and turn-process
  # monitors back to it.

  require Logger

  alias Raxol.Agent.Comm
  alias Raxol.Agent.Session.Lifecycle
  alias Raxol.Agent.Session.PromptTurn
  alias Raxol.Core.Runtime.EmitBus

  @type turn :: %{
          caller: pid(),
          caller_mref: reference(),
          agent_ref: reference(),
          turn_id: String.t(),
          pid: pid() | nil,
          mref: reference() | nil
        }

  @type state :: %{
          :id => term(),
          :session_id => String.t() | nil,
          :lifecycle_pid => pid() | nil,
          :turns => %{reference() => turn()},
          :agent_refs => %{reference() => reference()},
          :monitors => %{reference() => reference()},
          optional(atom()) => term()
        }

  @doc """
  Accept a prompt from `caller`. A non-binary text, an approver that is not
  a 3-arity function, or a ref already in flight is answered with an error.
  """
  @spec start(state(), pid(), reference(), term(), term(), map()) :: state()
  def start(state, caller, ref, text, approver, metadata) do
    cond do
      not is_binary(text) or not is_function(approver, 3) ->
        Comm.reply(caller, ref, {:error, :invalid_prompt})
        state

      Map.has_key?(state.turns, ref) ->
        Comm.reply(caller, ref, {:error, :duplicate_ref})
        state

      true ->
        dispatch(state, caller, ref, text, approver, metadata)
    end
  end

  # The agent gets a ref of the session's own: the caller's ref can only
  # cancel, while a holder of the agent ref can answer the turn.
  defp dispatch(state, caller, ref, text, approver, metadata) do
    case Lifecycle.dispatcher(state.lifecycle_pid) do
      nil ->
        Comm.reply(caller, ref, {:error, :no_dispatcher})
        state

      dispatcher ->
        agent_ref = make_ref()
        caller_mref = Process.monitor(caller)

        turn = %{
          caller: caller,
          caller_mref: caller_mref,
          agent_ref: agent_ref,
          turn_id: mint_turn_id(),
          pid: nil,
          mref: nil
        }

        # Opened before the agent sees the prompt, so it precedes every event
        # the turn's folds emit.
        bracket(state, turn, :turn_started, %{prompt: text})
        prompt = {:call, self(), agent_ref, {:acp_prompt, text, approver}}
        GenServer.cast(dispatcher, dispatch_cast(prompt, metadata))

        %{
          state
          | turns: Map.put(state.turns, ref, turn),
            agent_refs: Map.put(state.agent_refs, agent_ref, ref),
            monitors: Map.put(state.monitors, caller_mref, ref)
        }
    end
  end

  @doc "Cancel the turn the caller named `ref`."
  @spec cancel(state(), reference(), map(), :cancelled | :caller_down) ::
          {:ok | {:error, :not_found}, state()}
  def cancel(state, ref, metadata, reason \\ :cancelled) do
    if Map.has_key?(state.turns, ref) do
      closing = {:turn_canceled, %{reason: reason}}
      {:ok, end_turn(state, ref, {:error, :cancelled}, metadata, closing)}
    else
      {{:error, :not_found}, state}
    end
  end

  @doc "The agent answered inline. A running turn process is stopped first."
  @spec reply(state(), reference(), term()) :: state()
  def reply(state, agent_ref, reply) do
    ref = Map.fetch!(state.agent_refs, agent_ref)

    case Map.fetch!(state.turns, ref) do
      %{pid: nil} -> complete(state, ref, reply)
      %{pid: pid} when is_pid(pid) -> end_turn(state, ref, reply, %{}, {:turn_completed, %{}})
    end
  end

  @doc "The turn's process finished. Only a reply from the turn's owner counts."
  @spec finish(state(), reference(), pid(), term()) :: state()
  def finish(state, agent_ref, owner, reply) do
    ref = Map.fetch!(state.agent_refs, agent_ref)

    case Map.fetch!(state.turns, ref) do
      %{pid: ^owner} when is_pid(owner) -> complete(state, ref, reply)
      _other -> state
    end
  end

  @doc "Run `fun` as the turn's process. A second run for the same turn is ignored."
  @spec run(state(), reference(), (-> term())) :: state()
  def run(state, agent_ref, fun) do
    ref = Map.fetch!(state.agent_refs, agent_ref)

    case Map.fetch!(state.turns, ref) do
      %{pid: nil} = turn ->
        {pid, mref} = PromptTurn.start(self(), agent_ref, fun)

        %{
          state
          | turns: Map.put(state.turns, ref, %{turn | pid: pid, mref: mref}),
            monitors: Map.put(state.monitors, mref, ref)
        }

      %{pid: pid} ->
        Logger.warning(
          "[Agent.Session] #{inspect(state.id)} ignored a second run_turn for " <>
            "#{inspect(ref)}; turn already running in #{inspect(pid)}"
        )

        state
    end
  end

  @doc "Pass `message` to the turn's process, if one runs."
  @spec message(state(), reference(), term()) :: state()
  def message(state, agent_ref, message) do
    case Map.fetch!(state.turns, Map.fetch!(state.agent_refs, agent_ref)) do
      %{pid: pid} when is_pid(pid) -> send(pid, {:turn_message, message})
      %{pid: nil} -> :ok
    end

    state
  end

  @doc """
  The turn's worker crashed and its owner reported it. Believed only when
  `owner` is the turn's process; a forged report amounts to a cancel.
  """
  @spec failed(state(), reference(), pid()) :: state()
  def failed(state, agent_ref, owner) do
    ref = Map.fetch!(state.agent_refs, agent_ref)

    case Map.fetch!(state.turns, ref) do
      %{pid: ^owner, mref: mref} when is_pid(owner) ->
        PromptTurn.abort(owner, mref)
        fail(state, ref)

      _other ->
        state
    end
  end

  @doc """
  A monitored process went down: a turn process killed without reporting
  fails its turn, a caller that exited cancels its turn.
  """
  @spec down(state(), reference(), term()) :: state()
  def down(state, mref, reason) do
    ref = Map.fetch!(state.monitors, mref)

    case Map.fetch!(state.turns, ref) do
      %{mref: ^mref} ->
        Logger.warning(
          "[Agent.Session] turn #{inspect(ref)} died: #{PromptTurn.failure_shape(reason)}"
        )

        fail(state, ref)

      _caller_down ->
        {_result, state} = cancel(state, ref, %{}, :caller_down)
        state
    end
  end

  @doc "The agent is gone: answer every turn `{:error, :agent_down}`."
  @spec agent_down(state()) :: state()
  def agent_down(state) do
    Enum.each(state.turns, fn {ref, turn} ->
      Process.demonitor(turn.caller_mref)
      if turn.pid, do: PromptTurn.abort(turn.pid, turn.mref)
      bracket(state, turn, :error, %{reason: :agent_down})
      Comm.reply(turn.caller, ref, {:error, :agent_down})
    end)

    %{state | turns: %{}, agent_refs: %{}, monitors: %{}}
  end

  @doc """
  Cast `message` to the agent's dispatcher as `{:agent_message, from, message}`.
  `from` is the sender id in `metadata`, or nil; never the receiver's id.
  """
  @spec forward(state(), term(), map()) :: state()
  def forward(state, message, metadata) do
    case Lifecycle.dispatcher(state.lifecycle_pid) do
      nil ->
        Logger.debug(
          "[Agent.Session] #{inspect(state.id)} dropped message (no dispatcher): " <>
            inspect(message, limit: 5)
        )

      dispatcher ->
        GenServer.cast(dispatcher, dispatch_cast(message, metadata))
    end

    state
  end

  defp dispatch_cast(message, metadata) do
    {from, metadata} = Map.pop(metadata, :from)
    payload = {:agent_message, from, message}

    if map_size(metadata) == 0,
      do: {:dispatch, payload},
      else: {:dispatch, payload, metadata}
  end

  defp complete(state, ref, reply) do
    {turn, state} = forget(state, ref)
    Process.demonitor(turn.caller_mref)
    if turn.mref, do: Process.demonitor(turn.mref)
    bracket(state, turn, :turn_completed, %{})
    Comm.reply(turn.caller, ref, reply)
    state
  end

  # The turn process is stopped before the answer, so a cancel's `:ok` means
  # it is dead. Work the agent does inline in `update/2` is not stopped.
  defp end_turn(state, ref, answer, metadata, {closing_type, closing_payload}) do
    {turn, state} = forget(state, ref)
    Process.demonitor(turn.caller_mref)
    if turn.pid, do: PromptTurn.abort(turn.pid, turn.mref)
    bracket(state, turn, closing_type, closing_payload)
    Comm.reply(turn.caller, ref, answer)
    forward(state, {:acp_cancel, turn.agent_ref}, metadata)
  end

  # Callers make sure the turn's process is already down.
  defp fail(state, ref) do
    {turn, state} = forget(state, ref)
    Process.demonitor(turn.caller_mref)
    if turn.mref, do: Process.demonitor(turn.mref)
    bracket(state, turn, :error, %{reason: :turn_failed})
    Comm.reply(turn.caller, ref, {:error, :turn_failed})
    forward(state, {:acp_cancel, turn.agent_ref}, %{})
  end

  defp forget(state, ref) do
    {turn, turns} = Map.pop!(state.turns, ref)

    {turn,
     %{
       state
       | turns: turns,
         agent_refs: Map.delete(state.agent_refs, turn.agent_ref),
         monitors: Map.drop(state.monitors, [turn.caller_mref, turn.mref])
     }}
  end

  defp bracket(state, turn, type, payload) do
    state.session_id
    |> EmitBus.build(type, :durable, payload, turn_id: turn.turn_id)
    |> EmitBus.publish()
  end

  # Random rather than a counter: a journal outlives the BEAM.
  defp mint_turn_id,
    do: "acp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end

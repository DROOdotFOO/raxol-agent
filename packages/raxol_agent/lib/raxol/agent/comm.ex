defmodule Raxol.Agent.Comm do
  @moduledoc """
  Agent communication primitives.

  Agents discover each other via `Raxol.Agent.Registry`. Messages arrive in the
  target's `update/2` as `{:agent_message, from_id, payload}`; `from_id` is the
  `:from` option given to `send/3`, else `nil` (never guessed).

  ## Request-reply

  `call/3` delivers `{:call, caller_pid, ref, message}` as the payload; the
  receiver answers with `reply/3`, or the caller times out:

      def update({:agent_message, _from, {:call, caller, ref, question}}, model) do
        Raxol.Agent.Comm.reply(caller, ref, answer(question, model))
        {model, []}
      end

  ## Agent turn contract

  `call(agent, {:acp_prompt, text, approver}, timeout)` asks for one turn,
  answered `{:ok, text, usage}` (so the call returns `{:ok, {:ok, text, usage}}`).
  `approver` is an arity-3 `:tool_authorizer` (`Raxol.Agent.ToolPolicy`). The
  timeout is required (`{:error, :timeout_required}` otherwise) because a
  timeout cancels the turn; `:infinity` means no limit.

  The agent's `update/2` sees `{:call, session_pid, turn_ref, {:acp_prompt, ...}}`
  and answers inline with `reply/3` or via `run_turn/3` for blocking work.
  `turn_ref` is the session's ref, so a holder of only the caller's ref can
  cancel but not answer. `{:acp_cancel, ref}` (by `send/3`, or `call/3` for an
  `:ok` once the turn process is dead) stops the turn and answers
  `{:error, :cancelled}`; so does the caller going down or `call/4` timing out.
  `ref: ref` on `call/4` must be a fresh `make_ref/0`. The same envelopes sent
  raw with `send/3` work identically; an envelope with a non-pid or non-ref is
  dropped and logged (without the prompt).

  When a turn ends without its reply (cancelled or its `run_turn/3` process
  died), or an inline `reply/3` preempts a running `run_turn/3`, `update/2`
  receives `{:acp_cancel, turn_ref}`. Reply shapes are not checked. This
  `{:acp_cancel, ref}` is unrelated to the bare `:acp_cancel` atom of the ACP
  stack (see `Raxol.Agent.Session`).

  Consult `approver` and run gated actions in the `run_turn/3` process, never in
  `update/2`: inline work blocks the agent and a cancel cannot stop it. Send
  state changes back as `{:command_result, msg}` (see
  `Raxol.Agent.Reference.Counter`); a cancel does not roll back one already sent.

  Other prompt answers:

    * `{:error, :invalid_prompt}` - `text` not a binary or `approver` not arity 3
    * `{:error, :duplicate_ref}` - `ref` already names an in-flight turn
    * `{:error, :no_dispatcher}` - the agent is starting or restarting
    * `{:error, :turn_failed}` - the `run_turn/3` process crashed or was killed
    * `{:error, :agent_down}` - the agent's lifecycle went down mid-turn
    * `{:error, :cancelled}` - the turn was cancelled

  A cancel sent with `call/3` answers `:ok`, or `{:error, :not_found}` when no
  in-flight turn has that ref.
  """

  alias Raxol.Agent.Session

  @doc """
  Send an async message to another agent by id.

  Pass `from: my_agent_id` to identify the sender; it arrives as the
  second element of the `:agent_message` tuple (`nil` when omitted).
  """
  @spec send(term(), term(), keyword()) :: :ok | {:error, :not_found}
  def send(target_id, message, opts \\ []) do
    Session.send_message(target_id, message, Keyword.take(opts, [:from]))
  end

  @doc """
  `call/4` with the default 5 s timeout, for any message except an
  `{:acp_prompt, text, approver}`: a prompt needs an explicit timeout (it
  cancels the turn), so it is refused with `{:error, :timeout_required}`
  and never sent.
  """
  @spec call(term(), term()) ::
          {:ok, term()} | {:error, :timeout | :not_found | :agent_down | :timeout_required}
  def call(target_id, message)

  def call(_target_id, {:acp_prompt, _text, _approver}), do: {:error, :timeout_required}
  def call(target_id, message), do: call(target_id, message, 5_000)

  @doc """
  Synchronous request-reply with another agent.

  The target agent must answer with `reply/3` (see the module doc);
  otherwise this returns `{:error, :timeout}`. A target that dies before
  replying fails fast with `{:error, :agent_down}` instead of waiting out
  the timeout.

  Pass `ref: ref` to choose the request's ref (default `make_ref()`), so
  another process can name the request, as in `{:acp_cancel, ref}`. `ref`
  must be a fresh reference used for one call only: a late reply to an
  earlier call with the same ref would be taken as this call's answer.
  Raises `ArgumentError` when `ref` is not a reference.

  When an `{:acp_prompt, text, approver}` call times out, it sends the
  turn's `{:acp_cancel, ref}` before returning `{:error, :timeout}`.
  """
  @spec call(term(), term(), timeout(), keyword()) ::
          {:ok, term()} | {:error, :timeout | :not_found | :agent_down}
  def call(target_id, message, timeout, opts \\ []) do
    ref = call_ref(opts)

    case Registry.lookup(Raxol.Agent.Registry, target_id) do
      [{pid, _}] ->
        mref = Process.monitor(pid)
        GenServer.cast(pid, {:send_message, {:call, self(), ref, message}})

        receive do
          {:agent_reply, ^ref, reply} ->
            Process.demonitor(mref, [:flush])
            {:ok, reply}

          {:DOWN, ^mref, :process, ^pid, _reason} ->
            {:error, :agent_down}
        after
          timeout ->
            Process.demonitor(mref, [:flush])
            cancel_abandoned(pid, ref, message)
            flush_reply(ref)
            {:error, :timeout}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp call_ref(opts) do
    case Keyword.get_lazy(opts, :ref, &make_ref/0) do
      ref when is_reference(ref) -> ref
      other -> raise ArgumentError, "Comm.call/4 :ref must be a reference, got: #{inspect(other)}"
    end
  end

  # A prompt nobody waits for any more is aborted, not left running.
  defp cancel_abandoned(pid, ref, {:acp_prompt, _text, _approver}),
    do: GenServer.cast(pid, {:send_message, {:acp_cancel, ref}})

  defp cancel_abandoned(_pid, _ref, _message), do: :ok

  # Best-effort sweep of a reply that raced the timeout. A reply arriving
  # after this returns is abandoned in the caller's mailbox; callers doing
  # selective receives should treat stray {:agent_reply, _, _} as noise.
  defp flush_reply(ref) do
    receive do
      {:agent_reply, ^ref, _} -> :ok
    after
      0 -> :ok
    end
  end

  @doc "Answer a `{:call, caller, ref, message}` received via `call/3`."
  @spec reply(pid(), reference(), term()) :: :ok
  def reply(caller, ref, response) when is_pid(caller) and is_reference(ref) do
    Kernel.send(caller, {:agent_reply, ref, response})
    :ok
  end

  @doc """
  Answer an `{:acp_prompt, text, approver}` call by running `fun` in a turn
  process the session owns; `fun`'s return is the reply. Call it from
  `update/2` with the ref in the prompt it received (the session's
  `turn_ref`) and `session`, the pid in the prompt's caller position (the
  session stands in for the real caller).

  `{:acp_cancel, ref}` stops that process: it gets an exit signal with reason
  `:shutdown`, and `:kill` if it is still alive after
  `config :raxol_agent, :turn_cancel_grace_ms` (default 500). A `fun` that
  starts something its own death does not end (a Port's OS process) traps
  exits and, on `{:EXIT, _from, :shutdown}`, stops it before returning; a
  `fun` that does not trap exits ends at once.
  """
  @spec run_turn(pid(), reference(), (-> term())) :: :ok
  def run_turn(session, ref, fun)
      when is_pid(session) and is_reference(ref) and is_function(fun, 0) do
    Kernel.send(session, {:acp_run, ref, fun})
    :ok
  end

  @doc """
  Send `message` to the process running turn `ref` of `session` (see
  `run_turn/3`).
  """
  @spec send_turn(pid(), reference(), term()) :: :ok
  def send_turn(session, ref, message) when is_pid(session) and is_reference(ref) do
    Kernel.send(session, {:acp_turn_message, ref, message})
    :ok
  end

  @doc """
  Broadcast a message to all agents in a team.

  Delivery is filtered by the receiving session's `team_id` (set by
  `Raxol.Agent.Team` or the `:team_id` start option): only members of
  `team_id` see the message, as
  `{:agent_message, nil, {:team_broadcast, team_id, message}}`.
  """
  @spec broadcast_team(term(), term()) :: :ok
  def broadcast_team(team_id, message) do
    # Sessions register with the value :session; auxiliary entries in the
    # same Registry (lifecycles, emit bridges) carry other values and must
    # not receive the cast. uniq_by guards against a pid registered under
    # more than one session key.
    Registry.select(Raxol.Agent.Registry, [
      {{:"$1", :"$2", :session}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.uniq_by(fn {_id, pid} -> pid end)
    |> Enum.each(fn {_id, pid} ->
      GenServer.cast(pid, {:send_message, {:team_broadcast, team_id, message}})
    end)

    :ok
  end
end

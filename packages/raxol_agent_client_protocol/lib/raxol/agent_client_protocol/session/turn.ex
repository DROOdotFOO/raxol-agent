defmodule Raxol.AgentClientProtocol.Session.Turn do
  @moduledoc """
  State of one in-flight `session/prompt` turn, and the pure functions over it.

  `monitors` is the turn's task group (`monitor ref => pid`); the pids are kept
  so the cancel backstop can kill stragglers. The turn finishes once the group
  is empty and an `outcome` exists. The root task's result is written once; a
  cancel overwrites it with `{:stop, :cancelled}`.
  """

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{PromptResponse, StopReason}
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
  alias Raxol.AgentClientProtocol.Schema.{ContentChunk, TextContent}
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  @type outcome :: {:stop, StopReason.t()} | {:error, Error.t()}

  @type t :: %__MODULE__{
          turn_ref: reference(),
          reply_ref: reference(),
          prompt_seq: non_neg_integer(),
          root_ref: reference(),
          root_pid: pid(),
          monitors: %{reference() => pid()},
          outcome: outcome() | nil,
          pending_perms: %{reference() => %{from: GenServer.from()}},
          backstop_timer: reference() | nil,
          non_empty_prompt?: boolean(),
          updates_emitted?: boolean()
        }

  @enforce_keys [:turn_ref, :reply_ref, :prompt_seq, :root_ref, :root_pid, :monitors]
  defstruct turn_ref: nil,
            reply_ref: nil,
            prompt_seq: nil,
            root_ref: nil,
            root_pid: nil,
            monitors: %{},
            outcome: nil,
            pending_perms: %{},
            backstop_timer: nil,
            non_empty_prompt?: true,
            updates_emitted?: false

  @doc "A new turn whose root task is `task`."
  @spec new(Task.t(), reference(), non_neg_integer(), term()) :: t()
  def new(%Task{ref: ref, pid: pid}, reply_ref, prompt_seq, req) do
    %__MODULE__{
      turn_ref: make_ref(),
      reply_ref: reply_ref,
      prompt_seq: prompt_seq,
      root_ref: ref,
      root_pid: pid,
      monitors: %{ref => pid},
      non_empty_prompt?: prompt_non_empty?(req)
    }
  end

  @doc "Records the root task's return value; the first outcome wins."
  @spec fold_root(t(), term()) :: t()
  def fold_root(%__MODULE__{outcome: nil} = t, result), do: %{t | outcome: normalize(result)}
  def fold_root(%__MODULE__{} = t, _result), do: t

  @doc "Records a root-task crash as an internal error; the first outcome wins."
  @spec fold_crash(t()) :: t()
  def fold_crash(%__MODULE__{outcome: nil} = t),
    do: %{t | outcome: {:error, Error.internal_error()}}

  def fold_crash(%__MODULE__{} = t), do: t

  # A runner-built protocol error is kept, `data` included.
  defp normalize({:stop, reason}) when is_atom(reason), do: {:stop, reason}
  defp normalize(%PromptResponse{stop_reason: reason}), do: {:stop, reason}
  defp normalize({:error, %Error{} = err}), do: {:error, err}
  defp normalize(_other), do: {:error, Error.internal_error()}

  @spec drop_monitor(t(), reference()) :: t()
  def drop_monitor(%__MODULE__{} = t, ref), do: %{t | monitors: Map.delete(t.monitors, ref)}

  @spec drained?(t()) :: boolean()
  def drained?(%__MODULE__{monitors: monitors, outcome: outcome}),
    do: map_size(monitors) == 0 and outcome != nil

  @doc "The prompt response for an outcome."
  @spec render(outcome()) :: {:ok, PromptResponse.t()} | {:error, Error.t()}
  def render({:stop, reason}), do: {:ok, PromptResponse.new(reason)}
  def render({:error, %Error{} = e}), do: {:error, e}

  @doc """
  The stop reason when a non-empty prompt completed normally without posting a
  single `session/update` (an agent conformance violation), else `nil`.
  """
  @spec silent_completion(t()) :: StopReason.t() | nil
  def silent_completion(%__MODULE__{
        non_empty_prompt?: true,
        updates_emitted?: false,
        outcome: {:stop, reason}
      })
      when reason != :cancelled,
      do: reason

  def silent_completion(%__MODULE__{}), do: nil

  # Opaque request shapes (test doubles) are treated as empty, so the
  # zero-updates check never fires spuriously.
  defp prompt_non_empty?(%{prompt: prompt}) when is_list(prompt), do: prompt != []
  defp prompt_non_empty?(_other), do: false

  @doc "True for an agent message/thought chunk with empty text, which is never sent."
  @spec empty_chunk?(term()) :: boolean()
  def empty_chunk?(%SessionNotification{
        update: {tag, %ContentChunk{content: {:text, %TextContent{text: ""}}}}
      })
      when tag in [:agent_message_chunk, :agent_thought_chunk],
      do: true

  def empty_chunk?(_other), do: false

  @doc "Permission is granted only for a decoded `:selected` outcome; anything else denies."
  @spec permission_result(term()) :: {:ok, {:selected, struct()}} | {:ok, :cancelled}
  def permission_result({:ok, %RequestPermissionResponse{outcome: {:selected, sel}}}),
    do: {:ok, {:selected, sel}}

  def permission_result(_other), do: {:ok, :cancelled}
end

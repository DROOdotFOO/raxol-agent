defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest do
  @moduledoc """
  The `session/prompt` request: a turn's content blocks sent to the agent.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  @known_keys ["sessionId", "prompt", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          prompt: [ContentBlock.t()],
          _meta: map()
        }

  @enforce_keys [:session_id, :prompt]
  defstruct session_id: nil, prompt: nil, _meta: %{}

  @spec new(String.t(), [ContentBlock.t()]) :: t()
  def new(session_id, prompt),
    do: %__MODULE__{session_id: session_id, prompt: prompt}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "prompt" => Enum.map(r.prompt, &ContentBlock.to_json/1)
    }
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1),
         {:ok, raw_prompt} <- AgentTypes.fetch(map, "prompt"),
         {:ok, prompt} <-
           AgentTypes.decode_list(raw_prompt, &ContentBlock.from_json/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         prompt: prompt,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_prompt_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.StopReason do
  @moduledoc """
  Why a `session/prompt` turn ended.
  """

  @type t ::
          :end_turn | :max_tokens | :max_turn_requests | :refusal | :cancelled

  @spec to_json(t()) :: String.t()
  def to_json(:end_turn), do: "end_turn"
  def to_json(:max_tokens), do: "max_tokens"
  def to_json(:max_turn_requests), do: "max_turn_requests"
  def to_json(:refusal), do: "refusal"
  def to_json(:cancelled), do: "cancelled"

  @doc """
  Unrecognized strings return `{:error, {:invalid_stop_reason, value}}`.
  """
  @spec from_json(term()) ::
          {:ok, t()} | {:error, {:invalid_stop_reason, term()}}
  def from_json("end_turn"), do: {:ok, :end_turn}
  def from_json("max_tokens"), do: {:ok, :max_tokens}
  def from_json("max_turn_requests"), do: {:ok, :max_turn_requests}
  def from_json("refusal"), do: {:ok, :refusal}
  def from_json("cancelled"), do: {:ok, :cancelled}
  def from_json(other), do: {:error, {:invalid_stop_reason, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse do
  @moduledoc """
  The `session/prompt` response: why the turn ended.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.StopReason

  @known_keys ["stopReason", "_meta"]

  @type t :: %__MODULE__{stop_reason: StopReason.t(), _meta: map()}

  @enforce_keys [:stop_reason]
  defstruct stop_reason: nil, _meta: %{}

  @spec new(StopReason.t()) :: t()
  def new(stop_reason), do: %__MODULE__{stop_reason: stop_reason}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{"stopReason" => StopReason.to_json(r.stop_reason)},
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw} <- AgentTypes.fetch(map, "stopReason"),
         {:ok, stop_reason} <- StopReason.from_json(raw) do
      {:ok,
       %__MODULE__{
         stop_reason: stop_reason,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_prompt_response, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification do
  @moduledoc """
  The `session/cancel` notification.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), _meta: map()}

  @enforce_keys [:session_id]
  defstruct session_id: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"sessionId" => r.session_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_cancel_notification, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.ClientRequest do
  @moduledoc """
  Tagged union of every request the client may send to the agent, used for
  JSON-RPC method-name routing.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AuthenticateRequest,
    InitializeRequest,
    NewSessionRequest,
    PromptRequest,
    SetSessionModeRequest
  }

  alias Raxol.AgentClientProtocol.Schema.Ext.ExtRequest

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    ForkSessionRequest,
    ListSessionsRequest,
    ResumeSessionRequest,
    SetSessionConfigOptionRequest,
    SetSessionModelRequest
  }

  @type t ::
          {:initialize, InitializeRequest.t()}
          | {:authenticate, AuthenticateRequest.t()}
          | {:new_session, NewSessionRequest.t()}
          | {:load_session, LoadSessionRequest.t()}
          | {:list_sessions, ListSessionsRequest.t()}
          | {:fork_session, ForkSessionRequest.t()}
          | {:resume_session, ResumeSessionRequest.t()}
          | {:set_session_mode, SetSessionModeRequest.t()}
          | {:set_session_config_option, SetSessionConfigOptionRequest.t()}
          | {:prompt, PromptRequest.t()}
          | {:set_session_model, SetSessionModelRequest.t()}
          | {:ext_method, ExtRequest.t()}

  @spec method(t()) :: String.t()
  def method({:initialize, _}), do: "initialize"
  def method({:authenticate, _}), do: "authenticate"
  def method({:new_session, _}), do: "session/new"
  def method({:load_session, _}), do: "session/load"
  def method({:list_sessions, _}), do: "session/list"
  def method({:fork_session, _}), do: "session/fork"
  def method({:resume_session, _}), do: "session/resume"
  def method({:set_session_mode, _}), do: "session/set_mode"
  def method({:set_session_config_option, _}), do: "session/set_config_option"
  def method({:prompt, _}), do: "session/prompt"
  def method({:set_session_model, _}), do: "session/set_model"
  def method({:ext_method, req}), do: req.method
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AgentResponse do
  @moduledoc """
  Tagged union of every response the agent may send back to the client.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AuthenticateResponse,
    InitializeResponse,
    NewSessionResponse,
    PromptResponse,
    SetSessionModeResponse
  }

  alias Raxol.AgentClientProtocol.Schema.Ext.ExtResponse

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    ForkSessionResponse,
    ListSessionsResponse,
    ResumeSessionResponse,
    SetSessionConfigOptionResponse,
    SetSessionModelResponse
  }

  @type t ::
          {:initialize, InitializeResponse.t()}
          | {:authenticate, AuthenticateResponse.t()}
          | {:new_session, NewSessionResponse.t()}
          | {:load_session, LoadSessionResponse.t()}
          | {:list_sessions, ListSessionsResponse.t()}
          | {:fork_session, ForkSessionResponse.t()}
          | {:resume_session, ResumeSessionResponse.t()}
          | {:set_session_mode, SetSessionModeResponse.t()}
          | {:set_session_config_option, SetSessionConfigOptionResponse.t()}
          | {:prompt, PromptResponse.t()}
          | {:set_session_model, SetSessionModelResponse.t()}
          | {:ext_method, ExtResponse.t()}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.ClientNotification do
  @moduledoc """
  Tagged union of every notification the client may send to the agent, used
  for JSON-RPC method-name routing.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtNotification

  @type t ::
          {:cancel, CancelNotification.t()}
          | {:ext_notification, ExtNotification.t()}

  @spec method(t()) :: String.t()
  def method({:cancel, _}), do: "session/cancel"
  def method({:ext_notification, notif}), do: notif.method
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest,
    Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse,
    Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

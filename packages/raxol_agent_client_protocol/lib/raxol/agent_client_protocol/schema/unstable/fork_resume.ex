defmodule Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionRequest do
  @moduledoc """
  Request to fork an existing session (`session/fork`).
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer

  @known_keys ["sessionId", "cwd", "mcpServers", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          mcp_servers: [McpServer.t()],
          _meta: map()
        }

  @enforce_keys [:session_id, :cwd]
  defstruct session_id: nil, cwd: nil, mcp_servers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, cwd),
    do: %__MODULE__{session_id: session_id, cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "cwd" => r.cwd}
    |> maybe_put_mcp_servers(r.mcp_servers)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd"),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(
             Map.get(map, "mcpServers", []),
             &McpServer.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_fork_session_request, other}}

  defp maybe_put_mcp_servers(map, nil), do: map
  defp maybe_put_mcp_servers(map, []), do: map

  defp maybe_put_mcp_servers(map, servers) do
    Map.put(map, "mcpServers", Enum.map(servers, &McpServer.to_json/1))
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionResponse do
  @moduledoc """
  Response from forking a session: the new session id plus optional
  mode/model/config-option state.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{SessionModeState, SessionState}

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigOption,
    SessionModelState
  }

  @known_keys ["sessionId", "_meta" | SessionState.keys()]

  @type t :: %__MODULE__{
          session_id: String.t(),
          modes: SessionModeState.t() | nil,
          models: SessionModelState.t() | nil,
          config_options: [SessionConfigOption.t()] | nil,
          _meta: map()
        }

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            modes: nil,
            models: nil,
            config_options: nil,
            _meta: %{}

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id}
    |> SessionState.encode(r)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, state} <- SessionState.decode(map) do
      {:ok,
       Map.merge(
         %__MODULE__{session_id: session_id, _meta: AgentTypes.extract_meta(map, @known_keys)},
         state
       )}
    end
  end

  def from_json(other), do: {:error, {:invalid_fork_session_response, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionRequest do
  @moduledoc """
  Request to resume an existing session without replaying its history
  (`session/resume`).
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer

  @known_keys ["sessionId", "cwd", "mcpServers", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          mcp_servers: [McpServer.t()],
          _meta: map()
        }

  @enforce_keys [:session_id, :cwd]
  defstruct session_id: nil, cwd: nil, mcp_servers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, cwd),
    do: %__MODULE__{session_id: session_id, cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "cwd" => r.cwd}
    |> maybe_put_mcp_servers(r.mcp_servers)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd"),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(
             Map.get(map, "mcpServers", []),
             &McpServer.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_resume_session_request, other}}

  defp maybe_put_mcp_servers(map, nil), do: map
  defp maybe_put_mcp_servers(map, []), do: map

  defp maybe_put_mcp_servers(map, servers) do
    Map.put(map, "mcpServers", Enum.map(servers, &McpServer.to_json/1))
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionResponse do
  @moduledoc """
  Response from resuming a session: optional mode/model/config-option state.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{SessionModeState, SessionState}

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigOption,
    SessionModelState
  }

  @known_keys ["_meta" | SessionState.keys()]

  @type t :: %__MODULE__{
          modes: SessionModeState.t() | nil,
          models: SessionModelState.t() | nil,
          config_options: [SessionConfigOption.t()] | nil,
          _meta: map()
        }

  defstruct modes: nil, models: nil, config_options: nil, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{}
    |> SessionState.encode(r)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, state} <- SessionState.decode(map) do
      {:ok, Map.merge(%__MODULE__{_meta: AgentTypes.extract_meta(map, @known_keys)}, state)}
    end
  end

  def from_json(other), do: {:error, {:invalid_resume_session_response, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionRequest,
    Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionResponse,
    Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionRequest,
    Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionResponse
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

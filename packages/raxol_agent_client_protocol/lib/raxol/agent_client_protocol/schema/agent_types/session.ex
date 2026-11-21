defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest do
  @moduledoc """
  The `session/new` request: creates a new session rooted at `cwd`, optionally
  wiring up MCP servers.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer

  @known_keys ["cwd", "mcpServers", "_meta"]

  @type t :: %__MODULE__{
          cwd: String.t(),
          mcp_servers: [McpServer.t()],
          _meta: map()
        }

  @enforce_keys [:cwd]
  defstruct cwd: nil, mcp_servers: [], _meta: %{}

  @spec new(String.t()) :: t()
  def new(cwd), do: %__MODULE__{cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "cwd" => r.cwd,
      "mcpServers" => Enum.map(r.mcp_servers || [], &McpServer.to_json/1)
    }
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, cwd} <- AgentTypes.fetch(map, "cwd", &is_binary/1),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(
             Map.get(map, "mcpServers", []),
             &McpServer.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_new_session_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse do
  @moduledoc """
  The `session/new` response: the new session id plus optional mode/model/
  config-option state (the latter two are unstable extensions).
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
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1),
         {:ok, state} <- SessionState.decode(map) do
      {:ok,
       Map.merge(
         %__MODULE__{session_id: session_id, _meta: AgentTypes.extract_meta(map, @known_keys)},
         state
       )}
    end
  end

  def from_json(other), do: {:error, {:invalid_new_session_response, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest do
  @moduledoc """
  The `session/load` request: replays an existing session's history.
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
    %{
      "sessionId" => r.session_id,
      "cwd" => r.cwd,
      "mcpServers" => Enum.map(r.mcp_servers || [], &McpServer.to_json/1)
    }
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd", &is_binary/1),
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

  def from_json(other), do: {:error, {:invalid_load_session_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse do
  @moduledoc """
  The `session/load` response: optional mode/model/config-option state.
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

  def from_json(other), do: {:error, {:invalid_load_session_response, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState do
  @moduledoc """
  The set of available session modes and the one currently active.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode

  @known_keys ["currentModeId", "availableModes", "_meta"]

  @type t :: %__MODULE__{
          current_mode_id: String.t(),
          available_modes: [SessionMode.t()],
          _meta: map()
        }

  @enforce_keys [:current_mode_id, :available_modes]
  defstruct current_mode_id: nil, available_modes: nil, _meta: %{}

  @spec new(String.t(), [SessionMode.t()]) :: t()
  def new(current_mode_id, available_modes) do
    %__MODULE__{
      current_mode_id: current_mode_id,
      available_modes: available_modes
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "currentModeId" => s.current_mode_id,
      "availableModes" => Enum.map(s.available_modes, &SessionMode.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_mode_id} <- AgentTypes.fetch(map, "currentModeId"),
         {:ok, raw_modes} <- AgentTypes.fetch(map, "availableModes"),
         {:ok, available_modes} <-
           AgentTypes.decode_list(raw_modes, &SessionMode.from_json/1) do
      {:ok,
       %__MODULE__{
         current_mode_id: current_mode_id,
         available_modes: available_modes,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_mode_state, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode do
  @moduledoc """
  A single selectable session mode (e.g. "code", "ask").
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["id", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:id, :name]
  defstruct id: nil, name: nil, description: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(id, name), do: %__MODULE__{id: id, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = m) do
    %{"id" => m.id, "name" => m.name}
    |> AgentTypes.maybe_put("description", m.description)
    |> AgentTypes.put_meta(m._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, id} <- AgentTypes.fetch(map, "id"),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_mode, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeRequest do
  @moduledoc """
  The `session/set_mode` request.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "modeId", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          mode_id: String.t(),
          _meta: map()
        }

  @enforce_keys [:session_id, :mode_id]
  defstruct session_id: nil, mode_id: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, mode_id),
    do: %__MODULE__{session_id: session_id, mode_id: mode_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{"sessionId" => r.session_id, "modeId" => r.mode_id},
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1),
         {:ok, mode_id} <- AgentTypes.fetch(map, "modeId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         mode_id: mode_id,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_set_session_mode_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/set_mode`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: AgentTypes.put_meta(%{}, r._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_mode_response, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest,
    Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse,
    Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest,
    Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeRequest,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

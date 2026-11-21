defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo do
  @moduledoc """
  Information about a session returned by `session/list`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "cwd", "title", "updatedAt", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          title: String.t() | nil,
          updated_at: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:session_id, :cwd]
  defstruct session_id: nil, cwd: nil, title: nil, updated_at: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, cwd), do: %__MODULE__{session_id: session_id, cwd: cwd}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{"sessionId" => s.session_id, "cwd" => s.cwd}
    |> AgentTypes.maybe_put("title", s.title)
    |> AgentTypes.maybe_put("updatedAt", s.updated_at)
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    # List items stay presence-checked: a wrong-typed entry must not fail the
    # enclosing response.
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         title: Map.get(map, "title"),
         updated_at: Map.get(map, "updatedAt"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_info, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsRequest do
  @moduledoc """
  Request to list existing sessions (`session/list`).
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["cwd", "cursor", "_meta"]

  @type t :: %__MODULE__{
          cwd: String.t() | nil,
          cursor: String.t() | nil,
          _meta: map()
        }

  defstruct cwd: nil, cursor: nil, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{}
    |> AgentTypes.maybe_put("cwd", r.cwd)
    |> AgentTypes.maybe_put("cursor", r.cursor)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       cwd: Map.get(map, "cwd"),
       cursor: Map.get(map, "cursor"),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_list_sessions_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsResponse do
  @moduledoc """
  Response from listing sessions.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo

  @known_keys ["sessions", "nextCursor", "_meta"]

  @type t :: %__MODULE__{
          sessions: [SessionInfo.t()],
          next_cursor: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:sessions]
  defstruct sessions: nil, next_cursor: nil, _meta: %{}

  @spec new([SessionInfo.t()]) :: t()
  def new(sessions), do: %__MODULE__{sessions: sessions}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessions" => Enum.map(r.sessions, &SessionInfo.to_json/1)}
    |> AgentTypes.maybe_put("nextCursor", r.next_cursor)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_sessions} <- AgentTypes.fetch(map, "sessions"),
         {:ok, sessions} <-
           AgentTypes.decode_list(raw_sessions, &SessionInfo.from_json/1) do
      {:ok,
       %__MODULE__{
         sessions: sessions,
         next_cursor: Map.get(map, "nextCursor"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_list_sessions_response, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionListCapabilities do
  @moduledoc """
  Capability flag for `session/list`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: AgentTypes.put_meta(%{}, c._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_session_list_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionForkCapabilities do
  @moduledoc """
  Capability flag for `session/fork`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: AgentTypes.put_meta(%{}, c._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_session_fork_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionResumeCapabilities do
  @moduledoc """
  Capability flag for `session/resume`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: AgentTypes.put_meta(%{}, c._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_session_resume_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate do
  @moduledoc """
  Payload for the `session/update` notification's `session_info_update`
  variant: a partial update to session metadata.

  Fields are `Schema.MaybeUndefined` values:

    * `:undefined` — field not included on the wire (no change)
    * `nil` — explicitly `null` on the wire (clear the value)
    * `{:value, v}` — set to `v`
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.MaybeUndefined

  @known_keys ["title", "updatedAt", "_meta"]

  @type t :: %__MODULE__{
          title: MaybeUndefined.t(String.t()),
          updated_at: MaybeUndefined.t(String.t()),
          _meta: map()
        }

  defstruct title: :undefined, updated_at: :undefined, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{}
    |> maybe_put_maybe_undefined("title", s.title)
    |> maybe_put_maybe_undefined("updatedAt", s.updated_at)
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       title: decode_maybe_undefined(map, "title"),
       updated_at: decode_maybe_undefined(map, "updatedAt"),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_session_info_update, other}}

  defp decode_maybe_undefined(map, key) do
    if Map.has_key?(map, key) do
      MaybeUndefined.from_json(Map.get(map, key))
    else
      :undefined
    end
  end

  defp maybe_put_maybe_undefined(map, key, value) do
    case MaybeUndefined.to_json(value) do
      {:skip} -> map
      v -> Map.put(map, key, v)
    end
  end
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo,
    Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsRequest,
    Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsResponse,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionListCapabilities,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionForkCapabilities,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionResumeCapabilities,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

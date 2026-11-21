defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities do
  @moduledoc """
  Capabilities declared by the agent in the `initialize` response.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentAuthCapabilities,
    McpCapabilities,
    PromptCapabilities,
    SessionCapabilities
  }

  @known_keys [
    "loadSession",
    "promptCapabilities",
    "mcpCapabilities",
    "sessionCapabilities",
    "auth",
    "_meta"
  ]

  @type t :: %__MODULE__{
          load_session: boolean(),
          prompt_capabilities: PromptCapabilities.t() | nil,
          mcp_capabilities: McpCapabilities.t() | nil,
          session_capabilities: SessionCapabilities.t() | nil,
          auth: AgentAuthCapabilities.t() | nil,
          _meta: map()
        }

  defstruct load_session: false,
            prompt_capabilities: nil,
            mcp_capabilities: nil,
            session_capabilities: nil,
            auth: nil,
            _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"loadSession" => c.load_session}
    |> maybe_put_prompt(c.prompt_capabilities)
    |> maybe_put_mcp(c.mcp_capabilities)
    |> maybe_put_session(c.session_capabilities)
    |> maybe_put_auth(c.auth)
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, prompt_capabilities} <-
           AgentTypes.decode_optional(
             map,
             "promptCapabilities",
             &PromptCapabilities.from_json/1
           ),
         {:ok, mcp_capabilities} <-
           AgentTypes.decode_optional(
             map,
             "mcpCapabilities",
             &McpCapabilities.from_json/1
           ),
         {:ok, session_capabilities} <-
           AgentTypes.decode_optional(
             map,
             "sessionCapabilities",
             &SessionCapabilities.from_json/1
           ),
         {:ok, auth} <-
           AgentTypes.decode_optional(
             map,
             "auth",
             &AgentAuthCapabilities.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         load_session: AgentTypes.decode_bool(map, "loadSession"),
         prompt_capabilities: prompt_capabilities,
         mcp_capabilities: mcp_capabilities,
         session_capabilities: session_capabilities,
         auth: auth,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_agent_capabilities, other}}

  defp maybe_put_prompt(map, nil), do: map

  defp maybe_put_prompt(map, pc),
    do: Map.put(map, "promptCapabilities", PromptCapabilities.to_json(pc))

  defp maybe_put_mcp(map, nil), do: map

  defp maybe_put_mcp(map, mc),
    do: Map.put(map, "mcpCapabilities", McpCapabilities.to_json(mc))

  defp maybe_put_session(map, nil), do: map

  defp maybe_put_session(map, sc),
    do: Map.put(map, "sessionCapabilities", SessionCapabilities.to_json(sc))

  defp maybe_put_auth(map, nil), do: map

  defp maybe_put_auth(map, auth),
    do: Map.put(map, "auth", AgentAuthCapabilities.to_json(auth))
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.PromptCapabilities do
  @moduledoc """
  Content-block kinds the agent accepts in a `session/prompt`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["image", "audio", "embeddedContext", "_meta"]

  @type t :: %__MODULE__{
          image: boolean(),
          audio: boolean(),
          embedded_context: boolean(),
          _meta: map()
        }

  defstruct image: false, audio: false, embedded_context: false, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{
      "image" => c.image,
      "audio" => c.audio,
      "embeddedContext" => c.embedded_context
    }
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       image: AgentTypes.decode_bool(map, "image"),
       audio: AgentTypes.decode_bool(map, "audio"),
       embedded_context: AgentTypes.decode_bool(map, "embeddedContext"),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_prompt_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpCapabilities do
  @moduledoc """
  MCP transports the agent supports for client-provided MCP servers.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["http", "sse", "_meta"]

  @type t :: %__MODULE__{http: boolean(), sse: boolean(), _meta: map()}

  defstruct http: false, sse: false, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    AgentTypes.put_meta(%{"http" => c.http, "sse" => c.sse}, c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       http: AgentTypes.decode_bool(map, "http"),
       sse: AgentTypes.decode_bool(map, "sse"),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_mcp_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities do
  @moduledoc """
  Session-lifecycle capabilities the agent supports, including the unstable
  `list`/`fork`/`resume` extensions.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    SessionCloseCapabilities,
    SessionDeleteCapabilities
  }

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionForkCapabilities,
    SessionListCapabilities,
    SessionResumeCapabilities
  }

  @known_keys ["modes", "list", "fork", "resume", "delete", "close", "_meta"]

  @type t :: %__MODULE__{
          modes: boolean(),
          list: SessionListCapabilities.t() | nil,
          fork: SessionForkCapabilities.t() | nil,
          resume: SessionResumeCapabilities.t() | nil,
          delete: SessionDeleteCapabilities.t() | nil,
          close: SessionCloseCapabilities.t() | nil,
          _meta: map()
        }

  defstruct modes: false,
            list: nil,
            fork: nil,
            resume: nil,
            delete: nil,
            close: nil,
            _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"modes" => c.modes}
    |> maybe_put_list(c.list)
    |> maybe_put_fork(c.fork)
    |> maybe_put_resume(c.resume)
    |> maybe_put_delete(c.delete)
    |> maybe_put_close(c.close)
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, list} <-
           AgentTypes.decode_optional(
             map,
             "list",
             &SessionListCapabilities.from_json/1
           ),
         {:ok, fork} <-
           AgentTypes.decode_optional(
             map,
             "fork",
             &SessionForkCapabilities.from_json/1
           ),
         {:ok, resume} <-
           AgentTypes.decode_optional(
             map,
             "resume",
             &SessionResumeCapabilities.from_json/1
           ),
         {:ok, delete} <-
           AgentTypes.decode_optional(
             map,
             "delete",
             &SessionDeleteCapabilities.from_json/1
           ),
         {:ok, close} <-
           AgentTypes.decode_optional(
             map,
             "close",
             &SessionCloseCapabilities.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         modes: AgentTypes.decode_bool(map, "modes"),
         list: list,
         fork: fork,
         resume: resume,
         delete: delete,
         close: close,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_capabilities, other}}

  defp maybe_put_list(map, nil), do: map

  defp maybe_put_list(map, l),
    do: Map.put(map, "list", SessionListCapabilities.to_json(l))

  defp maybe_put_fork(map, nil), do: map

  defp maybe_put_fork(map, f),
    do: Map.put(map, "fork", SessionForkCapabilities.to_json(f))

  defp maybe_put_resume(map, nil), do: map

  defp maybe_put_resume(map, r),
    do: Map.put(map, "resume", SessionResumeCapabilities.to_json(r))

  defp maybe_put_delete(map, nil), do: map

  defp maybe_put_delete(map, d),
    do: Map.put(map, "delete", SessionDeleteCapabilities.to_json(d))

  defp maybe_put_close(map, nil), do: map

  defp maybe_put_close(map, cl),
    do: Map.put(map, "close", SessionCloseCapabilities.to_json(cl))
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionDeleteCapabilities do
  @moduledoc """
  Capability flag for `session/delete`: agent supports deleting sessions
  from `session/list`.
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
    do: {:error, {:invalid_session_delete_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCloseCapabilities do
  @moduledoc """
  Capability flag for `session/close`: agent supports closing sessions.
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
    do: {:error, {:invalid_session_close_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.LogoutCapabilities do
  @moduledoc """
  Capability flag for `logout`: agent supports the logout method.
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

  def from_json(other), do: {:error, {:invalid_logout_capabilities, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AgentAuthCapabilities do
  @moduledoc """
  Authentication-related capabilities supported by the agent: currently
  just the optional `logout` leaf.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LogoutCapabilities

  @known_keys ["logout", "_meta"]

  @type t :: %__MODULE__{logout: LogoutCapabilities.t() | nil, _meta: map()}

  defstruct logout: nil, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{}
    |> maybe_put_logout(c.logout)
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, logout} <-
           AgentTypes.decode_optional(
             map,
             "logout",
             &LogoutCapabilities.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         logout: logout,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_agent_auth_capabilities, other}}

  defp maybe_put_logout(map, nil), do: map

  defp maybe_put_logout(map, l),
    do: Map.put(map, "logout", LogoutCapabilities.to_json(l))
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.PromptCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.McpCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SessionDeleteCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCloseCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.LogoutCapabilities,
    Raxol.AgentClientProtocol.Schema.AgentTypes.AgentAuthCapabilities
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation do
  @moduledoc """
  Identifies an agent or client implementation (name, version, optional title).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["name", "version", "title", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          title: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:name, :version]
  defstruct name: nil, version: nil, title: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, version), do: %__MODULE__{name: name, version: version}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = impl) do
    %{"name" => impl.name, "version" => impl.version}
    |> AgentTypes.maybe_put("title", impl.title)
    |> AgentTypes.put_meta(impl._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, version} <- AgentTypes.fetch(map, "version") do
      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         title: Map.get(map, "title"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_implementation, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod do
  @moduledoc """
  A method by which a client may authenticate with an agent.
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

  def from_json(other), do: {:error, {:invalid_auth_method, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest do
  @moduledoc """
  The `initialize` request, sent by the client to negotiate protocol version
  and capabilities.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
  alias Raxol.AgentClientProtocol.Schema.Version

  @known_keys ["protocolVersion", "clientCapabilities", "clientInfo", "_meta"]

  @type t :: %__MODULE__{
          protocol_version: Version.t(),
          client_capabilities: ClientCapabilities.t() | nil,
          client_info: Implementation.t() | nil,
          _meta: map()
        }

  @enforce_keys [:protocol_version]
  defstruct protocol_version: nil,
            client_capabilities: nil,
            client_info: nil,
            _meta: %{}

  @spec new(Version.t()) :: t()
  def new(protocol_version) do
    %__MODULE__{
      protocol_version: protocol_version,
      client_capabilities: ClientCapabilities.new()
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"protocolVersion" => r.protocol_version}
    |> maybe_put_capabilities(r.client_capabilities)
    |> AgentTypes.put_encoded("clientInfo", r.client_info, &Implementation.to_json/1)
    |> AgentTypes.put_meta(r._meta)
  end

  @doc """
  Decodes an `initialize` request; the protocol version goes through
  `Version.coerce/1`, which tolerates legacy string versions.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_pv} <- AgentTypes.fetch(map, "protocolVersion"),
         {:ok, pv} <- Version.coerce(raw_pv),
         {:ok, client_capabilities} <-
           decode_client_capabilities(Map.get(map, "clientCapabilities")),
         {:ok, client_info} <-
           AgentTypes.decode_optional(
             map,
             "clientInfo",
             &Implementation.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         protocol_version: pv,
         client_capabilities: client_capabilities,
         client_info: client_info,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_initialize_request, other}}

  defp decode_client_capabilities(nil), do: {:ok, ClientCapabilities.new()}
  defp decode_client_capabilities(cc), do: ClientCapabilities.from_json(cc)

  defp maybe_put_capabilities(map, nil), do: map

  defp maybe_put_capabilities(map, cc) do
    if cc == ClientCapabilities.new(),
      do: map,
      else: Map.put(map, "clientCapabilities", ClientCapabilities.to_json(cc))
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse do
  @moduledoc """
  The `initialize` response, sent by the agent with its capabilities and
  supported authentication methods.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentCapabilities,
    AuthMethod,
    Implementation
  }

  alias Raxol.AgentClientProtocol.Schema.Version

  @known_keys [
    "protocolVersion",
    "agentCapabilities",
    "authMethods",
    "agentInfo",
    "_meta"
  ]

  @type t :: %__MODULE__{
          protocol_version: Version.t(),
          agent_capabilities: AgentCapabilities.t() | nil,
          auth_methods: [AuthMethod.t()] | nil,
          agent_info: Implementation.t() | nil,
          _meta: map()
        }

  @enforce_keys [:protocol_version]
  defstruct protocol_version: nil,
            agent_capabilities: nil,
            auth_methods: nil,
            agent_info: nil,
            _meta: %{}

  @spec new(Version.t()) :: t()
  def new(protocol_version) do
    %__MODULE__{
      protocol_version: protocol_version,
      agent_capabilities: AgentCapabilities.new(),
      auth_methods: []
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"protocolVersion" => r.protocol_version}
    |> maybe_put_capabilities(r.agent_capabilities)
    |> maybe_put_auth_methods(r.auth_methods)
    |> AgentTypes.put_encoded("agentInfo", r.agent_info, &Implementation.to_json/1)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_pv} <- AgentTypes.fetch(map, "protocolVersion"),
         {:ok, pv} <- Version.coerce(raw_pv),
         {:ok, agent_capabilities} <-
           decode_agent_capabilities(Map.get(map, "agentCapabilities")),
         {:ok, auth_methods} <-
           AgentTypes.decode_list(
             Map.get(map, "authMethods", []),
             &AuthMethod.from_json/1
           ),
         {:ok, agent_info} <-
           AgentTypes.decode_optional(
             map,
             "agentInfo",
             &Implementation.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         protocol_version: pv,
         agent_capabilities: agent_capabilities,
         auth_methods: auth_methods,
         agent_info: agent_info,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_initialize_response, other}}

  defp decode_agent_capabilities(nil), do: {:ok, AgentCapabilities.new()}
  defp decode_agent_capabilities(ac), do: AgentCapabilities.from_json(ac)

  defp maybe_put_capabilities(map, nil), do: map

  defp maybe_put_capabilities(map, ac) do
    if ac == AgentCapabilities.new(),
      do: map,
      else: Map.put(map, "agentCapabilities", AgentCapabilities.to_json(ac))
  end

  defp maybe_put_auth_methods(map, nil), do: map
  defp maybe_put_auth_methods(map, []), do: map

  defp maybe_put_auth_methods(map, methods) do
    Map.put(map, "authMethods", Enum.map(methods, &AuthMethod.to_json/1))
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest do
  @moduledoc """
  The `authenticate` request, sent by the client with the chosen auth method id.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["methodId", "_meta"]

  @type t :: %__MODULE__{method_id: String.t(), _meta: map()}

  @enforce_keys [:method_id]
  defstruct method_id: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(method_id), do: %__MODULE__{method_id: method_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"methodId" => r.method_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, method_id} <- AgentTypes.fetch(map, "methodId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         method_id: method_id,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_authenticate_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `authenticate`.
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

  def from_json(other), do: {:error, {:invalid_authenticate_response, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation,
    Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod,
    Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest,
    Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse,
    Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest,
    Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

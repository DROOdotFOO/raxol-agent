defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer do
  @moduledoc """
  A client-provided MCP server descriptor: tagged union of `http`, `sse`
  (both discriminated by a `"type"` wire field), and the untagged `stdio`
  fallback.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    McpServerHttp,
    McpServerSse,
    McpServerStdio
  }

  @type t ::
          {:http, McpServerHttp.t()}
          | {:sse, McpServerSse.t()}
          | {:stdio, McpServerStdio.t()}

  @spec to_json(t()) :: map()
  def to_json({:http, server}),
    do: Map.put(McpServerHttp.to_json(server), "type", "http")

  def to_json({:sse, server}),
    do: Map.put(McpServerSse.to_json(server), "type", "sse")

  def to_json({:stdio, server}), do: McpServerStdio.to_json(server)

  @doc """
  Dispatches on `"type"` (`http`/`sse`); a descriptor without one (or with
  `"stdio"`) decodes as the stdio variant, and any other type is refused.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"type" => "http"} = map) do
    case McpServerHttp.from_json(Map.delete(map, "type")) do
      {:ok, v} -> {:ok, {:http, v}}
      error -> error
    end
  end

  def from_json(%{"type" => "sse"} = map) do
    case McpServerSse.from_json(Map.delete(map, "type")) do
      {:ok, v} -> {:ok, {:sse, v}}
      error -> error
    end
  end

  # stdio descriptors carry no "type"; any other type is refused rather than
  # treated as a command to spawn.
  def from_json(%{"type" => type}) when type != "stdio",
    do: {:error, {:invalid_mcp_server_type, type}}

  def from_json(map) when is_map(map) do
    case McpServerStdio.from_json(Map.delete(map, "type")) do
      {:ok, v} -> {:ok, {:stdio, v}}
      error -> error
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp do
  @moduledoc """
  A streamable-HTTP MCP server descriptor.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader

  @known_keys ["name", "url", "headers", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          headers: [HttpHeader.t()],
          _meta: map()
        }

  @enforce_keys [:name, :url]
  defstruct name: nil, url: nil, headers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, url), do: %__MODULE__{name: name, url: url, headers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "name" => s.name,
      "url" => s.url,
      "headers" => Enum.map(s.headers || [], &HttpHeader.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name", &is_binary/1),
         {:ok, url} <- AgentTypes.fetch(map, "url", &is_binary/1),
         {:ok, headers} <-
           AgentTypes.decode_list(
             Map.get(map, "headers", []),
             &HttpHeader.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         name: name,
         url: url,
         headers: headers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server_http, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp

  def encode(%McpServerHttp{} = val, opts) do
    val
    |> McpServerHttp.to_json()
    |> Map.put("type", "http")
    |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse do
  @moduledoc """
  An SSE MCP server descriptor.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader

  @known_keys ["name", "url", "headers", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          headers: [HttpHeader.t()],
          _meta: map()
        }

  @enforce_keys [:name, :url]
  defstruct name: nil, url: nil, headers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, url), do: %__MODULE__{name: name, url: url, headers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "name" => s.name,
      "url" => s.url,
      "headers" => Enum.map(s.headers || [], &HttpHeader.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name", &is_binary/1),
         {:ok, url} <- AgentTypes.fetch(map, "url", &is_binary/1),
         {:ok, headers} <-
           AgentTypes.decode_list(
             Map.get(map, "headers", []),
             &HttpHeader.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         name: name,
         url: url,
         headers: headers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server_sse, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse

  def encode(%McpServerSse{} = val, opts) do
    val
    |> McpServerSse.to_json()
    |> Map.put("type", "sse")
    |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerStdio do
  @moduledoc """
  A stdio-launched MCP server descriptor (the untagged wire variant: no
  `"type"` field).
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable

  @known_keys ["name", "command", "args", "env", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: [EnvVariable.t()],
          _meta: map()
        }

  @enforce_keys [:name, :command]
  defstruct name: nil, command: nil, args: [], env: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, command),
    do: %__MODULE__{name: name, command: command, args: [], env: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "name" => s.name,
      "command" => s.command,
      "args" => s.args || [],
      "env" => Enum.map(s.env || [], &EnvVariable.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name", &is_binary/1),
         {:ok, command} <- AgentTypes.fetch(map, "command", &is_binary/1),
         {:ok, args} <- decode_args(Map.get(map, "args", [])),
         {:ok, env} <-
           AgentTypes.decode_list(
             Map.get(map, "env", []),
             &EnvVariable.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         name: name,
         command: command,
         args: args,
         env: env,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server_stdio, other}}

  # These fields end up in a spawned command line, so anything but a list of
  # strings is refused.
  defp decode_args(nil), do: {:ok, []}

  defp decode_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1),
      do: {:ok, args},
      else: {:error, {:invalid_field, "args", args}}
  end

  defp decode_args(other), do: {:error, {:invalid_field, "args", other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable do
  @moduledoc """
  A single `name=value` environment variable for a stdio-launched MCP server.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["name", "value", "_meta"]

  @type t :: %__MODULE__{name: String.t(), value: String.t(), _meta: map()}

  @enforce_keys [:name, :value]
  defstruct name: nil, value: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, value), do: %__MODULE__{name: name, value: value}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = e) do
    AgentTypes.put_meta(%{"name" => e.name, "value" => e.value}, e._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name", &is_binary/1),
         {:ok, value} <- AgentTypes.fetch(map, "value", &is_binary/1) do
      {:ok,
       %__MODULE__{
         name: name,
         value: value,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_env_variable, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader do
  @moduledoc """
  A single HTTP header for an HTTP/SSE MCP server.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["name", "value", "_meta"]

  @type t :: %__MODULE__{name: String.t(), value: String.t(), _meta: map()}

  @enforce_keys [:name, :value]
  defstruct name: nil, value: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, value), do: %__MODULE__{name: name, value: value}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = h) do
    AgentTypes.put_meta(%{"name" => h.name, "value" => h.value}, h._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name", &is_binary/1),
         {:ok, value} <- AgentTypes.fetch(map, "value", &is_binary/1) do
      {:ok,
       %__MODULE__{
         name: name,
         value: value,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_http_header, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerStdio,
    Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable,
    Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

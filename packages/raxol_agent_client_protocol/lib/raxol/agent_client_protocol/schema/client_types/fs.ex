defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest do
  @moduledoc """
  Request to write content to a text file (`fs/write_text_file`). Only sent
  if the client declared the `fs.writeTextFile` capability.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          path: String.t(),
          content: String.t(),
          _meta: map()
        }

  @enforce_keys [:session_id, :path, :content]
  defstruct [:session_id, :path, :content, _meta: %{}]

  @known_wire_keys ~w(sessionId path content)

  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(session_id, path, content) when is_binary(session_id) and is_binary(path) do
    %__MODULE__{session_id: session_id, path: path, content: content}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "path" => r.path, "content" => r.content}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`, `path`, or `content` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, path} <- WireFields.require(map, "path", &is_binary/1),
         {:ok, content} <- WireFields.require(map, "content", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         path: path,
         content: content,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_write_text_file_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse do
  @moduledoc """
  Response to `fs/write_text_file`. Carries no data of its own.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: WireFields.emit_meta(%{}, r._meta)

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map),
    do: {:ok, %__MODULE__{_meta: WireFields.fold_meta(map, [])}}

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest do
  @moduledoc """
  Request to read content from a text file (`fs/read_text_file`). Only sent
  if the client declared the `fs.readTextFile` capability.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          path: String.t(),
          line: non_neg_integer() | nil,
          limit: non_neg_integer() | nil,
          _meta: map()
        }

  @enforce_keys [:session_id, :path]
  defstruct [:session_id, :path, line: nil, limit: nil, _meta: %{}]

  @known_wire_keys ~w(sessionId path line limit)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, path) when is_binary(session_id) and is_binary(path) do
    %__MODULE__{session_id: session_id, path: path}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "path" => r.path}
    |> WireFields.put("line", r.line)
    |> WireFields.put("limit", r.limit)
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`path` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, path} <- WireFields.require(map, "path", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         path: path,
         line: WireFields.optional(map, "line", &is_integer/1),
         limit: WireFields.optional(map, "limit", &is_integer/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_read_text_file_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse do
  @moduledoc """
  Response containing the contents of a text file.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{content: String.t(), _meta: map()}

  @enforce_keys [:content]
  defstruct [:content, _meta: %{}]

  @known_wire_keys ~w(content)

  @spec new(String.t()) :: t()
  def new(content) when is_binary(content), do: %__MODULE__{content: content}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"content" => r.content} |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `content` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, content} <- WireFields.require(map, "content", &is_binary/1) do
      {:ok, %__MODULE__{content: content, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_read_text_file_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

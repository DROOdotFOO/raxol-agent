defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities do
  @moduledoc """
  Capabilities declared by the client at `initialize`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          terminal: boolean(),
          file_system: FileSystemCapability.t() | nil,
          _meta: map()
        }

  defstruct terminal: false, file_system: nil, _meta: %{}

  @known_wire_keys ~w(terminal fileSystem)

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"terminal" => c.terminal}
    |> then(fn map ->
      if c.file_system,
        do: Map.put(map, "fileSystem", FileSystemCapability.to_json(c.file_system)),
        else: map
    end)
    |> WireFields.emit_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, fs} <- decode_file_system(Map.get(map, "fileSystem")) do
      {:ok,
       %__MODULE__{
         terminal: Map.get(map, "terminal", false),
         file_system: fs,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_client_capabilities, other}}

  defp decode_file_system(nil), do: {:ok, nil}
  defp decode_file_system(fs), do: FileSystemCapability.from_json(fs)
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability do
  @moduledoc """
  File-system capabilities supported by the client.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          write_text_file: boolean(),
          read_text_file: boolean(),
          _meta: map()
        }

  defstruct write_text_file: false, read_text_file: false, _meta: %{}

  @known_wire_keys ~w(writeTextFile readTextFile)

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"writeTextFile" => c.write_text_file, "readTextFile" => c.read_text_file}
    |> WireFields.emit_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       write_text_file: Map.get(map, "writeTextFile", false),
       read_text_file: Map.get(map, "readTextFile", false),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_file_system_capability, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.AgentRequest do
  @moduledoc """
  Enum of all possible agent->client requests, with their wire method names.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes

  @type t ::
          {:write_text_file, ClientTypes.WriteTextFileRequest.t()}
          | {:read_text_file, ClientTypes.ReadTextFileRequest.t()}
          | {:request_permission, ClientTypes.RequestPermissionRequest.t()}
          | {:create_terminal, ClientTypes.CreateTerminalRequest.t()}
          | {:terminal_output, ClientTypes.TerminalOutputRequest.t()}
          | {:release_terminal, ClientTypes.ReleaseTerminalRequest.t()}
          | {:wait_for_terminal_exit, ClientTypes.WaitForTerminalExitRequest.t()}
          | {:kill_terminal_command, ClientTypes.KillTerminalRequest.t()}
          | {:ext_method, Raxol.AgentClientProtocol.Schema.Ext.ExtRequest.t()}

  @spec method(t()) :: String.t()
  def method({:write_text_file, _}), do: "fs/write_text_file"
  def method({:read_text_file, _}), do: "fs/read_text_file"
  def method({:request_permission, _}), do: "session/request_permission"
  def method({:create_terminal, _}), do: "terminal/create"
  def method({:terminal_output, _}), do: "terminal/output"
  def method({:release_terminal, _}), do: "terminal/release"
  def method({:wait_for_terminal_exit, _}), do: "terminal/wait_for_exit"
  def method({:kill_terminal_command, _}), do: "terminal/kill"
  def method({:ext_method, req}), do: req.method
end

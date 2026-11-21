defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest do
  @moduledoc """
  Request to create a new terminal and execute a command (`terminal/create`).
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          command: String.t(),
          args: [String.t()],
          env: [EnvVariable.t()],
          cwd: String.t() | nil,
          output_byte_limit: non_neg_integer() | nil,
          _meta: map()
        }

  @enforce_keys [:session_id, :command]
  defstruct [
    :session_id,
    :command,
    args: [],
    env: [],
    cwd: nil,
    output_byte_limit: nil,
    _meta: %{}
  ]

  @known_wire_keys ~w(sessionId command args env cwd outputByteLimit)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, command) when is_binary(session_id) and is_binary(command) do
    %__MODULE__{session_id: session_id, command: command}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "command" => r.command,
      "args" => r.args || [],
      "env" => Enum.map(r.env || [], &EnvVariable.to_json/1)
    }
    |> WireFields.put("cwd", r.cwd)
    |> WireFields.put("outputByteLimit", r.output_byte_limit)
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`command` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, command} <- WireFields.require(map, "command", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         command: command,
         args: WireFields.list_lenient(Map.get(map, "args"), &decode_arg/1, []),
         env: WireFields.list_lenient(Map.get(map, "env"), &EnvVariable.from_json/1, []),
         cwd: WireFields.optional(map, "cwd", &is_binary/1),
         output_byte_limit: WireFields.optional(map, "outputByteLimit", &is_integer/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_create_terminal_request, other}}

  defp decode_arg(arg) when is_binary(arg), do: {:ok, arg}
  defp decode_arg(other), do: {:error, {:invalid_arg, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse do
  @moduledoc """
  Response containing the ID of the newly created terminal.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{terminal_id: String.t(), _meta: map()}

  @enforce_keys [:terminal_id]
  defstruct [:terminal_id, _meta: %{}]

  @known_wire_keys ~w(terminalId)

  @spec new(String.t()) :: t()
  def new(terminal_id) when is_binary(terminal_id), do: %__MODULE__{terminal_id: terminal_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"terminalId" => r.terminal_id} |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{terminal_id: terminal_id, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_create_terminal_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest do
  @moduledoc """
  Request to get the current output and status of a terminal
  (`terminal/output`).
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{session_id: String.t(), terminal_id: String.t(), _meta: map()}

  @enforce_keys [:session_id, :terminal_id]
  defstruct [:session_id, :terminal_id, _meta: %{}]

  @known_wire_keys ~w(sessionId terminalId)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, terminal_id) when is_binary(session_id) and is_binary(terminal_id) do
    %__MODULE__{session_id: session_id, terminal_id: terminal_id}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "terminalId" => r.terminal_id}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         terminal_id: terminal_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_terminal_output_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus do
  @moduledoc """
  Exit status of a terminal command: an exit code (normal exit) and/or a
  signal name (killed by signal), independently nullable per the
  schema.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          exit_code: non_neg_integer() | nil,
          signal: String.t() | nil,
          _meta: map()
        }

  defstruct exit_code: nil, signal: nil, _meta: %{}

  @known_wire_keys ~w(exitCode signal)

  @spec new(non_neg_integer() | nil, String.t() | nil) :: t()
  def new(exit_code \\ nil, signal \\ nil), do: %__MODULE__{exit_code: exit_code, signal: signal}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{}
    |> WireFields.put("exitCode", s.exit_code)
    |> WireFields.put("signal", s.signal)
    |> WireFields.emit_meta(s._meta)
  end

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       exit_code: WireFields.optional(map, "exitCode", &is_integer/1),
       signal: WireFields.optional(map, "signal", &is_binary/1),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse do
  @moduledoc """
  Response containing the terminal output captured so far, and its exit
  status if the command has completed.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          output: String.t(),
          truncated: boolean(),
          exit_status: TerminalExitStatus.t() | nil,
          _meta: map()
        }

  @enforce_keys [:output, :truncated]
  defstruct [:output, :truncated, exit_status: nil, _meta: %{}]

  @known_wire_keys ~w(output truncated exitStatus)

  @spec new(String.t(), boolean()) :: t()
  def new(output, truncated \\ false) when is_binary(output) and is_boolean(truncated) do
    %__MODULE__{output: output, truncated: truncated}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"output" => r.output, "truncated" => r.truncated}
    |> WireFields.put("exitStatus", encode_exit_status(r.exit_status))
    |> WireFields.emit_meta(r._meta)
  end

  defp encode_exit_status(nil), do: nil
  defp encode_exit_status(%TerminalExitStatus{} = status), do: TerminalExitStatus.to_json(status)

  @doc """
  Requires `output` and `truncated`; an unparseable `exitStatus` decodes as `nil`.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, output} <- WireFields.require(map, "output", &is_binary/1),
         {:ok, truncated} <- WireFields.require(map, "truncated", &is_boolean/1) do
      {:ok,
       %__MODULE__{
         output: output,
         truncated: truncated,
         exit_status:
           WireFields.optional_nested(map, "exitStatus", &TerminalExitStatus.from_json/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_terminal_output_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

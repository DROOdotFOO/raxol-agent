defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest do
  @moduledoc """
  Request to release a terminal and free its resources (`terminal/release`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
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

  def from_json(other), do: {:error, {:invalid_release_terminal_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse do
  @moduledoc """
  Response to `terminal/release`. Carries no data of its own.
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

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest do
  @moduledoc """
  Request to wait for a terminal command to exit (`terminal/wait_for_exit`).
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

  def from_json(other), do: {:error, {:invalid_wait_for_terminal_exit_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse do
  @moduledoc """
  Exit status of a terminal command; `exitCode`/`signal` are flat on the
  response, both nullable.
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
  def to_json(%__MODULE__{} = r) do
    %{}
    |> WireFields.put("exitCode", r.exit_code)
    |> WireFields.put("signal", r.signal)
    |> WireFields.emit_meta(r._meta)
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

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest do
  @moduledoc """
  Request to kill a terminal command without releasing the terminal
  (`terminal/kill`).
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

  def from_json(other), do: {:error, {:invalid_kill_terminal_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse do
  @moduledoc """
  Response to `terminal/kill`. Carries no data of its own.
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

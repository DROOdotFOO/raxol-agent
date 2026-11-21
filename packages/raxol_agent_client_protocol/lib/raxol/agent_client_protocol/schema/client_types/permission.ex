defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOptionKind do
  @moduledoc """
  Hint about the nature of a `PermissionOption`, so clients can choose
  appropriate icons/UI treatment. Unrecognized values are a decode error (no
  safe default exists for a safety-relevant field).
  """

  @type t :: :allow_once | :allow_always | :reject_once | :reject_always

  @spec to_json(t()) :: String.t()
  def to_json(:allow_once), do: "allow_once"
  def to_json(:allow_always), do: "allow_always"
  def to_json(:reject_once), do: "reject_once"
  def to_json(:reject_always), do: "reject_always"

  @doc "Total: never raises. An unrecognized wire value is an error, not a silently-coerced default."
  @spec from_json(term()) :: {:ok, t()} | {:error, {:invalid_permission_option_kind, term()}}
  def from_json("allow_once"), do: {:ok, :allow_once}
  def from_json("allow_always"), do: {:ok, :allow_always}
  def from_json("reject_once"), do: {:ok, :reject_once}
  def from_json("reject_always"), do: {:ok, :reject_always}
  def from_json(other), do: {:error, {:invalid_permission_option_kind, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption do
  @moduledoc """
  An option presented to the user when the agent requests permission for a
  tool call.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOptionKind
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          option_id: String.t(),
          name: String.t(),
          kind: PermissionOptionKind.t(),
          _meta: map()
        }

  @enforce_keys [:option_id, :name, :kind]
  defstruct [:option_id, :name, :kind, _meta: %{}]

  @known_wire_keys ~w(optionId name kind)

  @spec new(String.t(), String.t(), PermissionOptionKind.t()) :: t()
  def new(option_id, name, kind) when is_binary(option_id) and is_binary(name) do
    %__MODULE__{option_id: option_id, name: name, kind: kind}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = p) do
    %{"optionId" => p.option_id, "name" => p.name, "kind" => PermissionOptionKind.to_json(p.kind)}
    |> WireFields.emit_meta(p._meta)
  end

  @doc "Total: never raises. Missing/invalid `optionId`, `name`, or `kind` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, option_id} <- WireFields.require(map, "optionId", &is_binary/1),
         {:ok, name} <- WireFields.require(map, "name", &is_binary/1),
         {:ok, kind_json} <- WireFields.require(map, "kind", &is_binary/1),
         {:ok, kind} <- PermissionOptionKind.from_json(kind_json) do
      {:ok,
       %__MODULE__{
         option_id: option_id,
         name: name,
         kind: kind,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_permission_option, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome do
  @moduledoc """
  A `RequestPermissionOutcome` variant: the user selected one of the
  offered options.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{option_id: String.t(), _meta: map()}

  @enforce_keys [:option_id]
  defstruct [:option_id, _meta: %{}]

  @known_wire_keys ~w(optionId outcome)

  @spec new(String.t()) :: t()
  def new(option_id) when is_binary(option_id), do: %__MODULE__{option_id: option_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{"optionId" => s.option_id} |> WireFields.emit_meta(s._meta)
  end

  @doc "Total: never raises. Missing/non-string `optionId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, option_id} <- WireFields.require(map, "optionId", &is_binary/1) do
      {:ok, %__MODULE__{option_id: option_id, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_selected_permission_outcome, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionOutcome do
  @moduledoc """
  The outcome of a permission request: either the prompt turn was cancelled
  before the user responded, or the user selected one of the offered
  options. Tagged by the wire `outcome` field.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome

  @type t :: :cancelled | {:selected, SelectedPermissionOutcome.t()}

  @spec to_json(t()) :: map()
  def to_json(:cancelled), do: %{"outcome" => "cancelled"}

  def to_json({:selected, %SelectedPermissionOutcome{} = selected}) do
    selected |> SelectedPermissionOutcome.to_json() |> Map.put("outcome", "selected")
  end

  @doc "Total: never raises. Missing/unrecognized `outcome` discriminator is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"outcome" => "cancelled"}), do: {:ok, :cancelled}

  def from_json(%{"outcome" => "selected"} = map) do
    with {:ok, selected} <- SelectedPermissionOutcome.from_json(map) do
      {:ok, {:selected, selected}}
    end
  end

  def from_json(%{"outcome" => other}), do: {:error, {:invalid_outcome, other}}
  def from_json(map) when is_map(map), do: {:error, {:missing_field, "outcome"}}
  def from_json(other), do: {:error, {:invalid_request_permission_outcome, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse do
  @moduledoc """
  Response to a `session/request_permission` request, carrying the user's
  decision.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionOutcome
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{outcome: RequestPermissionOutcome.t(), _meta: map()}

  @enforce_keys [:outcome]
  defstruct [:outcome, _meta: %{}]

  @known_wire_keys ~w(outcome)

  @spec new(RequestPermissionOutcome.t()) :: t()
  def new(outcome), do: %__MODULE__{outcome: outcome}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"outcome" => RequestPermissionOutcome.to_json(r.outcome)}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. A missing/unparseable `outcome` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"outcome" => outcome_json} = map) do
    with {:ok, outcome} <- RequestPermissionOutcome.from_json(outcome_json) do
      {:ok, %__MODULE__{outcome: outcome, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "outcome"}}
  def from_json(other), do: {:error, {:invalid_request_permission_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest do
  @moduledoc """
  Request from the agent asking the client for permission to perform a tool
  call, sent before a sensitive operation.

  `options` decodes leniently (missing or invalid entries are dropped); only
  `sessionId` and `toolCall` can fail decode.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          tool_call: ToolCallUpdate.t(),
          options: [PermissionOption.t()],
          _meta: map()
        }

  @enforce_keys [:session_id, :tool_call]
  defstruct [:session_id, :tool_call, options: [], _meta: %{}]

  @known_wire_keys ~w(sessionId toolCall options)

  @spec new(String.t(), ToolCallUpdate.t(), [PermissionOption.t()]) :: t()
  def new(session_id, tool_call, options \\ []) when is_binary(session_id) do
    %__MODULE__{session_id: session_id, tool_call: tool_call, options: options}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "toolCall" => ToolCallUpdate.to_json(r.tool_call),
      "options" => Enum.map(r.options, &PermissionOption.to_json/1)
    }
    |> WireFields.emit_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"toolCall" => tool_call_json} = map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, tool_call} <- ToolCallUpdate.from_json(tool_call_json) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         tool_call: tool_call,
         options:
           WireFields.list_lenient(Map.get(map, "options"), &PermissionOption.from_json/1, []),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "toolCall"}}
  def from_json(other), do: {:error, {:invalid_request_permission_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

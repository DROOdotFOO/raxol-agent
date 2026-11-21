defmodule Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo do
  @moduledoc """
  Information about a selectable model.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["modelId", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          model_id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:model_id, :name]
  defstruct model_id: nil, name: nil, description: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(model_id, name), do: %__MODULE__{model_id: model_id, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = m) do
    %{"modelId" => m.model_id, "name" => m.name}
    |> AgentTypes.maybe_put("description", m.description)
    |> AgentTypes.put_meta(m._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, model_id} <- AgentTypes.fetch(map, "modelId", &is_binary/1),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         model_id: model_id,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_model_info, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionModelState do
  @moduledoc """
  The set of selectable models and the one currently active.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo

  @known_keys ["currentModelId", "availableModels", "_meta"]

  @type t :: %__MODULE__{
          current_model_id: String.t(),
          available_models: [ModelInfo.t()],
          _meta: map()
        }

  @enforce_keys [:current_model_id, :available_models]
  defstruct current_model_id: nil, available_models: nil, _meta: %{}

  @spec new(String.t(), [ModelInfo.t()]) :: t()
  def new(current_model_id, available_models) do
    %__MODULE__{
      current_model_id: current_model_id,
      available_models: available_models
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "currentModelId" => s.current_model_id,
      "availableModels" => Enum.map(s.available_models, &ModelInfo.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_model_id} <- AgentTypes.fetch(map, "currentModelId"),
         {:ok, raw_models} <- AgentTypes.fetch(map, "availableModels"),
         {:ok, available_models} <-
           AgentTypes.decode_list(raw_models, &ModelInfo.from_json/1) do
      {:ok,
       %__MODULE__{
         current_model_id: current_model_id,
         available_models: available_models,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_model_state, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelRequest do
  @moduledoc """
  Request to set the active model for a session (`session/set_model`).
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "modelId", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          model_id: String.t(),
          _meta: map()
        }

  @enforce_keys [:session_id, :model_id]
  defstruct session_id: nil, model_id: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, model_id),
    do: %__MODULE__{session_id: session_id, model_id: model_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{"sessionId" => r.session_id, "modelId" => r.model_id},
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1),
         {:ok, model_id} <- AgentTypes.fetch(map, "modelId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         model_id: model_id,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_model_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/set_model`.
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
    do: {:error, {:invalid_set_session_model_response, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionModelState,
    Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelRequest,
    Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelResponse
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

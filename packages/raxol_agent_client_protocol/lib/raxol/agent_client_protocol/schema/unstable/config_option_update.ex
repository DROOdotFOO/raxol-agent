defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionRequest do
  @moduledoc """
  Request to set a session configuration option value
  (`session/set_config_option`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "configId", "value", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          config_id: String.t(),
          value: term(),
          _meta: map()
        }

  @enforce_keys [:session_id, :config_id, :value]
  defstruct session_id: nil, config_id: nil, value: nil, _meta: %{}

  @spec new(String.t(), String.t(), term()) :: t()
  def new(session_id, config_id, value) do
    %__MODULE__{session_id: session_id, config_id: config_id, value: value}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{
        "sessionId" => r.session_id,
        "configId" => r.config_id,
        "value" => r.value
      },
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, config_id} <- AgentTypes.fetch(map, "configId"),
         {:ok, value} <- AgentTypes.fetch(map, "value") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         config_id: config_id,
         value: value,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_config_option_request, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionResponse do
  @moduledoc """
  Response to `session/set_config_option`: the full, refreshed set of config
  options.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption

  @known_keys ["configOptions", "_meta"]

  @type t :: %__MODULE__{
          config_options: [SessionConfigOption.t()],
          _meta: map()
        }

  @enforce_keys [:config_options]
  defstruct config_options: nil, _meta: %{}

  @spec new([SessionConfigOption.t()]) :: t()
  def new(config_options), do: %__MODULE__{config_options: config_options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{
        "configOptions" => Enum.map(r.config_options, &SessionConfigOption.to_json/1)
      },
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_opts} <- AgentTypes.fetch(map, "configOptions"),
         {:ok, config_options} <-
           AgentTypes.decode_list(raw_opts, &SessionConfigOption.from_json/1) do
      {:ok,
       %__MODULE__{
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_config_option_response, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate do
  @moduledoc """
  Payload for the `session/update` notification's `config_option_update`
  variant: session configuration options have been updated.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption

  @known_keys ["configOptions", "_meta"]

  @type t :: %__MODULE__{
          config_options: [SessionConfigOption.t()],
          _meta: map()
        }

  @enforce_keys [:config_options]
  defstruct config_options: nil, _meta: %{}

  @spec new([SessionConfigOption.t()]) :: t()
  def new(config_options), do: %__MODULE__{config_options: config_options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    AgentTypes.put_meta(
      %{
        "configOptions" => Enum.map(c.config_options, &SessionConfigOption.to_json/1)
      },
      c._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, config_options} <-
           AgentTypes.decode_list(
             Map.get(map, "configOptions", []),
             &SessionConfigOption.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_config_option_update, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionRequest,
    Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionResponse,
    Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionState do
  @moduledoc false
  # The optional `modes`/`models`/`configOptions` trio shared by the
  # session/new, load, fork and resume responses.

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState
  alias Raxol.AgentClientProtocol.Schema.Unstable.{SessionConfigOption, SessionModelState}

  @type t :: %{
          modes: SessionModeState.t() | nil,
          models: SessionModelState.t() | nil,
          config_options: [SessionConfigOption.t()] | nil
        }

  @keys ["modes", "models", "configOptions"]

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec decode(map()) :: {:ok, t()} | {:error, term()}
  def decode(map) do
    with {:ok, modes} <- AgentTypes.decode_optional(map, "modes", &SessionModeState.from_json/1),
         {:ok, models} <-
           AgentTypes.decode_optional(map, "models", &SessionModelState.from_json/1),
         {:ok, config_options} <- AgentTypes.decode_optional(map, "configOptions", &decode_opts/1) do
      {:ok, %{modes: modes, models: models, config_options: config_options}}
    end
  end

  @spec encode(map(), t() | struct()) :: map()
  def encode(json, state) do
    json
    |> AgentTypes.put_encoded("modes", state.modes, &SessionModeState.to_json/1)
    |> AgentTypes.put_encoded("models", state.models, &SessionModelState.to_json/1)
    |> AgentTypes.put_encoded("configOptions", state.config_options, &encode_opts/1)
  end

  defp decode_opts(opts), do: AgentTypes.decode_list(opts, &SessionConfigOption.from_json/1)
  defp encode_opts(opts), do: Enum.map(opts, &SessionConfigOption.to_json/1)
end

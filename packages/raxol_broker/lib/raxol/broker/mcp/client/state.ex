defmodule Raxol.Broker.MCP.Client.State do
  @moduledoc false

  alias Raxol.Agent.Auth.Credential

  @type status :: :connecting | :refreshing | :ready | :unauthorized
  @type tables :: %{eras: :ets.table(), breakers: :ets.tid(), reservations: :ets.table()}
  @type attempt :: %{
          retried: boolean(),
          throttled: non_neg_integer(),
          last: term(),
          resend: boolean(),
          deadline: integer() | :infinity
        }
  @type request :: :list_tools | {:call, String.t(), map()}
  @type t :: %__MODULE__{
          credential: Credential.t(),
          inner: pid() | nil,
          tables: tables() | nil,
          reservations: :ets.table(),
          tools: [map()] | nil,
          live: [map()] | nil,
          task: {:connect | :refresh, reference()} | nil,
          reconnect_ref: reference() | nil,
          timer: reference() | nil,
          unpersisted: Credential.t() | nil,
          status: status(),
          generation: non_neg_integer(),
          reconnects: non_neg_integer(),
          failed_runs: non_neg_integer(),
          cooldown: %{until: integer(), reason: term()} | nil,
          scheduled_retries: non_neg_integer(),
          fresh: boolean(),
          queue: [{GenServer.from(), request(), attempt()}],
          requests: %{
            optional(reference()) => {GenServer.from(), request(), attempt(), non_neg_integer()}
          },
          config: map()
        }

  defstruct [
    :credential,
    :inner,
    :tables,
    :reservations,
    :tools,
    :live,
    :task,
    :reconnect_ref,
    :timer,
    :unpersisted,
    status: :connecting,
    generation: 0,
    reconnects: 0,
    failed_runs: 0,
    cooldown: nil,
    scheduled_retries: 0,
    fresh: false,
    queue: [],
    requests: %{},
    config: %{}
  ]

  @doc """
  `term` with every credential replaced and a state's config, queue and
  requests cut to what is safe to print (the client's `format_status/1`).
  """
  @spec scrub(term()) :: term()
  def scrub(%Credential{}), do: :redacted_credential

  def scrub(%__MODULE__{} = state) do
    %{
      state
      | credential: scrub(state.credential),
        unpersisted: scrub(state.unpersisted),
        config: Map.take(state.config, [:url, :skew, :connect_timeout]),
        queue: length(state.queue),
        requests: map_size(state.requests)
    }
  end

  def scrub(%_{} = struct), do: struct

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()

  def scrub([_ | _] = list) do
    if List.improper?(list), do: list, else: Enum.map(list, &scrub/1)
  end

  def scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  def scrub(other), do: other

  defimpl Inspect do
    def inspect(state, _opts) do
      "#Raxol.Broker.MCP.Client.State<status: #{inspect(state.status)}, " <>
        "generation: #{state.generation}, tools: #{tool_count(state.tools)}>"
    end

    defp tool_count(nil), do: "nil"
    defp tool_count(tools), do: Integer.to_string(length(tools))
  end
end

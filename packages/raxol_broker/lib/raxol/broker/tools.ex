defmodule Raxol.Broker.Tools do
  @moduledoc """
  The read tools as typed functions. `Raxol.Broker.Tools.<Family>` modules
  are generated from the capture by `mix raxol.broker.gen.tools` (see
  `Raxol.Broker.Tools.Generator`); each function validates its arguments
  against the captured `inputSchema` and calls the read-only session.

  Only `:read` tools are generated. Review and order tools are reached only
  through `Raxol.Broker.Executor`, never through a function here.
  """

  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Tools.{Catalog, Schema}

  # Rules stated only in descriptions, not the captured JSON Schema.
  @exactly_one %{
    "get_equity_technical_indicators" => ["symbol", "symbols"],
    "get_index_quotes" => ["instrument_ids", "symbols"]
  }
  @at_least_one %{"get_politician_trades" => ["politician_name", "equity_symbol"]}

  @doc """
  The arguments of which a call to `tool` must pass exactly one, or `[]`.
  An argument that is absent or `nil` is not passed.
  """
  @spec exactly_one(String.t()) :: [String.t()]
  def exactly_one(tool) when is_binary(tool), do: Map.get(@exactly_one, tool, [])

  @doc "The arguments of which a call must pass at least one nonblank string, or `[]`."
  @spec at_least_one(String.t()) :: [String.t()]
  def at_least_one(tool) when is_binary(tool), do: Map.get(@at_least_one, tool, [])

  @doc """
  Validate `args` against `tool`'s captured schema, then call it on the
  read-only session `client`.
  """
  @spec call(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(client, tool, args) when is_binary(tool) and is_map(args) do
    with :read <- Catalog.classify(tool),
         :ok <- validate(tool, args) do
      Client.call(client, tool, args)
    else
      {:error, _} = error -> error
      class -> {:error, {:tool_refused, tool, class}}
    end
  end

  defp validate(tool, args) do
    with :ok <- Schema.validate(Catalog.schema(tool), args),
         :ok <- one_of(exactly_one(tool), args),
         :ok <- nonempty_selection(tool, args),
         :ok <- at_least_one_of(at_least_one(tool), args) do
      :ok
    else
      {:error, errors} -> {:error, {:invalid_args, tool, errors}}
    end
  end

  defp one_of([], _args), do: :ok

  defp one_of(keys, args) do
    case Enum.count(keys, &(Map.get(args, &1) != nil)) do
      1 -> :ok
      _none_or_several -> {:error, [{[], {:exactly_one_of, keys}}]}
    end
  end

  defp nonempty_selection("get_index_quotes" = tool, args) do
    keys = exactly_one(tool)
    selection = Enum.find_value(keys, &Map.get(args, &1))

    if is_list(selection) and selection != [] and Enum.all?(selection, &nonblank?/1),
      do: :ok,
      else: {:error, [{[], {:nonempty_selection, keys}}]}
  end

  defp nonempty_selection(_tool, _args), do: :ok

  defp at_least_one_of([], _args), do: :ok

  defp at_least_one_of(keys, args) do
    if Enum.any?(keys, &nonblank?(Map.get(args, &1))),
      do: :ok,
      else: {:error, [{[], {:at_least_one_of, keys}}]}
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end

defmodule Raxol.Broker.Strategy do
  @moduledoc """
  A trading strategy: a pure state machine from feed messages to intents.

  A strategy never calls a tool. `Raxol.Broker.Strategy.Runner` feeds it
  messages, journals each intent it emits, and hands the intent to
  `Raxol.Broker.Executor`, the one path to an order.

    * `init/1` takes the strategy's parameters as a string-keyed map of
      strings (the form they are journaled and typed in) and returns its
      model, or `{:error, reason}` for parameters it cannot run with.
    * `update/2` takes a message and the model and returns the new model and
      the intents to send, in order. Messages are `{:quote, symbol, quote}`
      from `Raxol.Broker.Feed`, where `quote` is `%{last: Decimal.t(), bid:
      Decimal.t() | nil, ask: Decimal.t() | nil}`; anything else should be
      returned unchanged with no intents.
    * `symbols/1` lists the symbols the strategy wants quotes for.

  ## Specs

  A strategy is added as a spec: `%{"id" => id, "strategy" => name,
  "params" => params}`, where `name` is one of `names/0`. `spec/3` builds
  and validates one.
  """

  alias Raxol.Broker.Intent

  @callback init(params :: %{String.t() => String.t()}) :: {:ok, term()} | {:error, term()}
  @callback update(message :: term(), model :: term()) :: {term(), [Intent.t()]}
  @callback symbols(model :: term()) :: [String.t()]

  @strategies %{"dip_buy" => Raxol.Broker.Strategy.DipBuy}

  @type spec :: %{String.t() => term()}

  @doc "The strategy names a spec may use."
  @spec names() :: [String.t()]
  def names, do: @strategies |> Map.keys() |> Enum.sort()

  @doc "The module implementing strategy `name`."
  @spec module(String.t()) :: {:ok, module()} | {:error, {:unknown_strategy, term()}}
  def module(name) do
    case Map.fetch(@strategies, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_strategy, name}}
    end
  end

  @doc """
  Build a spec for strategy `name` with `params`, checked by the strategy's
  own `init/1`. `id` defaults to `name` and the first symbol, joined by `-`.
  """
  @spec spec(String.t(), map(), String.t() | nil) :: {:ok, spec()} | {:error, term()}
  def spec(name, params, id \\ nil) when is_map(params) do
    with {:ok, module} <- module(name),
         {:ok, model} <- module.init(params) do
      id = id || Enum.join([name | Enum.take(module.symbols(model), 1)], "-")
      {:ok, %{"id" => id, "strategy" => name, "params" => params}}
    end
  end

  @doc "Start a spec's model: `{:ok, module, model}`."
  @spec start(spec()) :: {:ok, module(), term()} | {:error, term()}
  def start(%{"strategy" => name, "params" => params}) when is_map(params) do
    with {:ok, module} <- module(name),
         {:ok, model} <- module.init(params),
         do: {:ok, module, model}
  end

  def start(other), do: {:error, {:invalid_spec, other}}

  @doc "The symbols a spec's strategy wants quotes for."
  @spec symbols(spec()) :: {:ok, [String.t()]} | {:error, term()}
  def symbols(spec) do
    with {:ok, module, model} <- start(spec), do: {:ok, module.symbols(model)}
  end
end

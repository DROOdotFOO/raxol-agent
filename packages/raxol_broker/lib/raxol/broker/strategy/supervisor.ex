defmodule Raxol.Broker.Strategy.Supervisor do
  @moduledoc """
  Runs one `Raxol.Broker.Strategy.Runner` per added strategy.

  A `:one_for_all` supervisor of three children:

    * a `Registry` of runners keyed by strategy id. A runner registers
      itself on start, so two runners for one id cannot exist, and every
      lookup (`running/1`, `stop/2`, `list/1`) reads the registry instead of
      calling a runner that may be busy in the executor;
    * a `DynamicSupervisor` of the runners;
    * `Raxol.Broker.Strategy.Restorer`, which starts every strategy the
      journal holds as added (`restore/1`) whenever it starts.

  `:one_for_all` because a crash of the runners' supervisor must also
  replace the registry: the old runners leave it asynchronously, and a
  restorer that read their entries before they left would skip restarting
  them. A fresh registry is empty, so the restorer starts every added
  strategy.

  Adding and stopping are journaled (`Raxol.Broker.Journal.put_strategy/2`,
  `drop_strategy/2`), so `mix raxol.broker.strategy` can add or stop one
  while the broker is not running.

  ## Options

  `start_link/1`: `:name` (default this module), `:restore` (default
  `true`), and for every runner `:journal` (default `Raxol.Broker.Journal`),
  `:executor` (default `Raxol.Broker.Executor`), `:feed` (default nil, no
  quotes) and `:retry_ms`. The functions below take `:supervisor` (default
  this module) and `:journal`.
  """

  use Supervisor

  require Logger

  alias Raxol.Broker.{Journal, Redact, Strategy}
  alias Raxol.Broker.Strategy.{Restorer, Runner}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, config} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, {name, config}, name: name)
  end

  @impl Supervisor
  def init({name, config}) do
    {restore?, config} = Keyword.pop(config, :restore, true)
    journal = Keyword.get(config, :journal, Journal)
    runner_config = Keyword.put(config, :registry, registry(name))

    children =
      [
        {Registry, keys: :unique, name: registry(name)},
        {DynamicSupervisor,
         name: runners(name), strategy: :one_for_one, extra_arguments: [runner_config]}
      ] ++ if(restore?, do: [{Restorer, supervisor: name, journal: journal}], else: [])

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Journal `spec` as added and start its runner, when the supervisor is
  running. `{:error, {:already_added, id}}` for an id already added.
  """
  @spec add(Strategy.spec(), keyword()) :: :ok | {:error, term()}
  def add(%{"id" => id} = spec, opts \\ []) do
    journal = Keyword.get(opts, :journal, Journal)

    update(journal, fn ->
      with {:ok, _module, _model} <- Strategy.start(spec),
           {:ok, specs} <- Journal.strategies(journal),
           :ok <- not_added(specs, id),
           :ok <- Journal.put_strategy(spec, journal) do
        start_runner(supervisor(opts), spec)
      end
    end)
  end

  @doc """
  Stop the runner for `id`, if running, and journal it as stopped. The
  runner is found in the registry and terminated even while it waits on the
  executor.
  """
  @spec stop(String.t(), keyword()) :: :ok | {:error, term()}
  def stop(id, opts \\ []) when is_binary(id) do
    journal = Keyword.get(opts, :journal, Journal)
    update(journal, fn -> stop_added(journal, supervisor(opts), id) end)
  end

  defp stop_added(journal, sup, id) do
    with {:ok, specs} <- Journal.strategies(journal),
         true <- Enum.any?(specs, &(&1["id"] == id)) || {:error, {:not_added, id}} do
      for {pid, %{id: ^id}} <- running(sup), do: terminate(sup, pid)
      Journal.drop_strategy(id, journal)
    end
  end

  @doc """
  Every added strategy: `%{id, strategy, params, status}`, with `status`
  `:running` for one whose runner is up and `:stopped` otherwise.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, specs} <- Journal.strategies(Keyword.get(opts, :journal, Journal)) do
      running = Map.new(running(supervisor(opts)), fn {_pid, info} -> {info.id, info} end)

      {:ok,
       Enum.map(specs, fn spec ->
         case Map.fetch(running, spec["id"]) do
           {:ok, info} ->
             Map.drop(info, [:symbols])

           :error ->
             %{
               id: spec["id"],
               strategy: spec["strategy"],
               params: spec["params"],
               status: :stopped
             }
         end
       end)}
    end
  end

  @doc """
  Start a runner for every added strategy that is not running. A runner
  that fails to start is logged and the rest are still started.
  """
  @spec restore(keyword()) :: :ok | {:error, term()}
  def restore(opts \\ []) do
    journal = Keyword.get(opts, :journal, Journal)
    update(journal, fn -> restore_added(journal, supervisor(opts)) end)
  end

  defp restore_added(journal, sup) do
    with {:ok, specs} <- Journal.strategies(journal) do
      up = MapSet.new(running(sup), fn {_pid, info} -> info.id end)

      for spec <- specs, not MapSet.member?(up, spec["id"]), do: restore_runner(sup, spec)

      :ok
    end
  end

  @doc "Stop every running runner (the strategies stay added)."
  @spec stop_all(keyword()) :: :ok
  def stop_all(opts \\ []) do
    sup = supervisor(opts)
    Enum.each(running(sup), fn {pid, _info} -> terminate(sup, pid) end)
  end

  @doc """
  `[{pid, info}]` for each running runner, read from the registry (no runner
  is called); `[]` when the supervisor is not running. `info` is what the
  runner registered: `%{id, strategy, params, symbols, status}`.
  """
  @spec running(GenServer.server()) :: [{pid(), map()}]
  def running(sup \\ __MODULE__) do
    registry = registry(sup)

    if Process.whereis(registry) do
      registry
      |> Registry.select([{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.sort_by(fn {_pid, info} -> info.id end)
    else
      []
    end
  end

  @doc false
  @spec registry(atom()) :: atom()
  def registry(sup), do: :"#{sup}.Registry"

  defp runners(sup), do: :"#{sup}.Runners"

  # Keep the journal check, mutation and runner transition together on this
  # node. The lock also works for offline tasks with no strategy supervisor.
  defp update(journal, fun) do
    case :global.trans({{__MODULE__, journal}, self()}, fun, [node()]) do
      :aborted -> {:error, :strategy_update_aborted}
      result -> result
    end
  end

  defp terminate(sup, pid) do
    _ = DynamicSupervisor.terminate_child(runners(sup), pid)
    :ok
  end

  defp not_added(specs, id) do
    if Enum.any?(specs, &(&1["id"] == id)), do: {:error, {:already_added, id}}, else: :ok
  end

  defp restore_runner(sup, spec) do
    with {:error, reason} <- start_runner(sup, spec) do
      Logger.error(
        "[Broker.Strategy] #{spec["id"]} not restored: " <>
          inspect(Redact.collapse(reason), structs: false)
      )
    end
  end

  defp start_runner(sup, spec) do
    if Process.whereis(runners(sup)) do
      case DynamicSupervisor.start_child(runners(sup), {Runner, spec}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp supervisor(opts), do: Keyword.get(opts, :supervisor, __MODULE__)
end

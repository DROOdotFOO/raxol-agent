defmodule Raxol.Broker.Strategy.Supervisor do
  @moduledoc """
  A `DynamicSupervisor` of `Raxol.Broker.Strategy.Runner`s, one per added
  strategy.

  Adding and stopping are journaled (`Raxol.Broker.Journal.put_strategy/2`,
  `drop_strategy/2`), so `restore/1` starts the strategies that were added
  and not stopped when the broker starts again, and
  `mix raxol.broker.strategy` can add or stop one while the broker is not
  running.

  ## Options

  `start_link/1`: `:name` (default this module), and for every runner
  `:journal` (default `Raxol.Broker.Journal`), `:executor` (default
  `Raxol.Broker.Executor`), `:feed` (default nil, no quotes) and
  `:retry_ms`. The functions below take `:supervisor` (default this module)
  and `:journal`.
  """

  use DynamicSupervisor

  alias Raxol.Broker.{Journal, Strategy}
  alias Raxol.Broker.Strategy.Runner

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, config} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, config, name: name)
  end

  @impl DynamicSupervisor
  def init(config), do: DynamicSupervisor.init(strategy: :one_for_one, extra_arguments: [config])

  @doc """
  Journal `spec` as added and start its runner, when the supervisor is
  running. `{:error, {:already_added, id}}` for an id already added.
  """
  @spec add(Strategy.spec(), keyword()) :: :ok | {:error, term()}
  def add(%{"id" => id} = spec, opts \\ []) do
    journal = Keyword.get(opts, :journal, Journal)

    with {:ok, _module, _model} <- Strategy.start(spec),
         {:ok, specs} <- Journal.strategies(journal),
         :ok <- not_added(specs, id),
         :ok <- Journal.put_strategy(spec, journal) do
      start_runner(supervisor(opts), spec)
    end
  end

  @doc "Stop the runner for `id`, if running, and journal it as stopped."
  @spec stop(String.t(), keyword()) :: :ok | {:error, term()}
  def stop(id, opts \\ []) when is_binary(id) do
    journal = Keyword.get(opts, :journal, Journal)

    with {:ok, specs} <- Journal.strategies(journal),
         true <- Enum.any?(specs, &(&1["id"] == id)) || {:error, {:not_added, id}} do
      sup = supervisor(opts)
      for {pid, %{id: ^id}} <- running(sup), do: DynamicSupervisor.terminate_child(sup, pid)
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

  @doc "Start a runner for every added strategy that is not running."
  @spec restore(keyword()) :: :ok | {:error, term()}
  def restore(opts \\ []) do
    with {:ok, specs} <- Journal.strategies(Keyword.get(opts, :journal, Journal)) do
      sup = supervisor(opts)
      up = MapSet.new(running(sup), fn {_pid, info} -> info.id end)
      for spec <- specs, not MapSet.member?(up, spec["id"]), do: start_runner(sup, spec)
      :ok
    end
  end

  @doc "Stop every running runner (the strategies stay added)."
  @spec stop_all(keyword()) :: :ok
  def stop_all(opts \\ []) do
    sup = supervisor(opts)

    if GenServer.whereis(sup) do
      for {pid, _info} <- running(sup), do: DynamicSupervisor.terminate_child(sup, pid)
    end

    :ok
  end

  @doc "`[{pid, info}]` for each running runner; `[]` when the supervisor is not running."
  @spec running(GenServer.server()) :: [{pid(), map()}]
  def running(sup \\ __MODULE__) do
    if GenServer.whereis(sup) do
      sup
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
        case is_pid(pid) && safe_info(pid) do
          %{} = info -> [{pid, info}]
          _gone -> []
        end
      end)
    else
      []
    end
  end

  defp safe_info(pid) do
    Runner.info(pid)
  catch
    :exit, _reason -> nil
  end

  defp not_added(specs, id) do
    if Enum.any?(specs, &(&1["id"] == id)), do: {:error, {:already_added, id}}, else: :ok
  end

  defp start_runner(sup, spec) do
    if GenServer.whereis(sup) do
      case DynamicSupervisor.start_child(sup, {Runner, spec}) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp supervisor(opts), do: Keyword.get(opts, :supervisor, __MODULE__)
end

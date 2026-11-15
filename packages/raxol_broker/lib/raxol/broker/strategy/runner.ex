defmodule Raxol.Broker.Strategy.Runner do
  @moduledoc """
  Runs one strategy spec (see `Raxol.Broker.Strategy`): subscribes to the
  feed for the strategy's symbols, passes each feed message to its
  `update/2`, and sends every intent it emits through the executor.

  Each intent is journaled with `Raxol.Broker.Journal.emit/3` before the
  executor sees it, and marked with `Raxol.Broker.Journal.dispatched/3` once
  the executor answers. On start the runner re-sends every intent its id
  emitted that was never marked, with the same intent id, so a runner killed
  between the two is recovered from the journal: the executor's idempotency
  check (`Raxol.Broker.Journal.placing_for_intent/2`) answers `{:ok,
  :duplicate}` for one that already reached `placing`, and the `ref_id` sent
  with a place derives from the same id.

  An executor that is not ready (`{:error, :port_not_ready}`) or not running
  leaves the intent pending; the runner retries pending intents after
  `:retry_ms` (default 5_000). An intent the journal could not record is
  never sent.

  The context sent with each intent carries the last quote price of every
  symbol the runner has seen.

  The runner registers itself in the strategy supervisor's registry under
  its strategy id, with `%{id, strategy, params, symbols, status}` as the
  value, so it is found without being called. It subscribes to the feed
  with a cast, so a feed busy polling never delays its start.

  ## Options

  From the strategy supervisor: `:registry`, `:journal`, `:executor`,
  `:feed` (nil: no
  subscription) and `:retry_ms`. Then the spec map.
  """

  use GenServer

  require Logger

  alias Raxol.Broker.{Executor, Feed, Journal, Strategy}
  alias Raxol.Broker.Policy.Context

  @default_retry_ms 5_000

  # The strategy supervisor prepends its config to the start arguments.
  @spec child_spec(Strategy.spec()) :: Supervisor.child_spec()
  def child_spec(%{"id" => id} = spec) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [spec]}}
  end

  @spec start_link(keyword(), Strategy.spec()) :: GenServer.on_start()
  def start_link(config, %{"id" => id} = spec) do
    case Strategy.start(spec) do
      {:ok, module, model} ->
        info = %{
          id: id,
          strategy: spec["strategy"],
          params: spec["params"],
          symbols: module.symbols(model),
          status: :running,
          paused: []
        }

        name = {:via, Registry, {Keyword.fetch!(config, :registry), id, info}}
        GenServer.start_link(__MODULE__, {config, spec, module, model}, name: name)

      {:error, reason} ->
        {:error, {:invalid_strategy, reason}}
    end
  end

  @impl GenServer
  def init({config, %{"id" => id} = spec, module, model}) do
    state = %{
      id: id,
      spec: spec,
      module: module,
      model: model,
      journal: Keyword.get(config, :journal, Journal),
      executor: Keyword.get(config, :executor, Executor),
      registry: Keyword.fetch!(config, :registry),
      retry_ms: Keyword.get(config, :retry_ms, @default_retry_ms),
      quotes: %{},
      paused: [],
      retry: nil
    }

    if feed = Keyword.get(config, :feed), do: Feed.subscribe(feed, module.symbols(model))
    {:ok, state, {:continue, :recover}}
  end

  @impl GenServer
  def handle_continue(:recover, state), do: {:noreply, send_pending(state)}

  # A paused runner ignores feed messages: its strategy sees no quote and
  # emits nothing until every reason it was paused for is resumed.
  @impl GenServer
  def handle_info({:quote, _symbol, _quote}, %{paused: [_ | _]} = state),
    do: {:noreply, state}

  def handle_info({:quote, symbol, %{last: price}} = message, state) do
    {model, intents} = state.module.update(message, state.model)
    state = %{state | model: model, quotes: Map.put(state.quotes, symbol, price)}
    {:noreply, Enum.reduce(intents, state, &emit/2)}
  end

  def handle_info({:pause, reason}, state),
    do: {:noreply, paused(state, Enum.sort(Enum.uniq([reason | state.paused])))}

  def handle_info({:resume, reason}, state),
    do: {:noreply, paused(state, List.delete(state.paused, reason))}

  def handle_info(:retry, state), do: {:noreply, send_pending(%{state | retry: nil})}
  def handle_info(_message, state), do: {:noreply, state}

  # The registry value carries the pause, so it is read without a call.
  defp paused(state, reasons) do
    status = if reasons == [], do: :running, else: :paused
    _ = Registry.update_value(state.registry, state.id, &%{&1 | status: status, paused: reasons})
    %{state | paused: reasons}
  end

  defp emit(intent, state) do
    case Journal.emit(intent, state.id, state.journal) do
      :ok ->
        dispatch(intent, state)

      {:error, reason} ->
        Logger.error(
          "[Broker.Strategy] #{state.id}: intent not journaled, not sent: " <>
            inspect(reason, structs: false)
        )

        state
    end
  end

  defp send_pending(state) do
    case Journal.pending_intents(state.id, state.journal) do
      {:ok, intents} ->
        Enum.reduce(intents, state, &dispatch/2)

      {:error, reason} ->
        Logger.warning(
          "[Broker.Strategy] #{state.id}: pending intents unreadable: " <>
            inspect(reason, structs: false)
        )

        retry_later(state)
    end
  end

  defp dispatch(intent, state) do
    context = %Context{quotes: state.quotes}

    case outcome(run(state.executor, intent, context)) do
      :retry ->
        retry_later(state)

      outcome ->
        with {:error, reason} <- Journal.dispatched(intent.id, outcome, state.journal) do
          Logger.warning(
            "[Broker.Strategy] #{state.id}: dispatch of #{intent.id} not journaled: " <>
              inspect(reason, structs: false)
          )
        end

        state
    end
  end

  defp run(executor, intent, context) do
    Executor.run(executor, intent, context)
  catch
    :exit, reason -> {:error, {:executor_down, reason}}
  end

  defp outcome({:ok, :duplicate}), do: "duplicate"
  defp outcome({:ok, %{status: status}}), do: Atom.to_string(status)
  defp outcome({:error, :not_armed}), do: "not_armed"
  defp outcome({:ask, _group_id, _prompts}), do: "ask"
  defp outcome({:deny, _group_id, _reason}), do: "deny"
  defp outcome({:error, :port_not_ready}), do: :retry
  defp outcome({:error, {:executor_down, _reason}}), do: :retry
  defp outcome({:error, {:context, _reason}}), do: :retry
  defp outcome({:error, _reason}), do: "error"

  defp retry_later(%{retry: nil} = state),
    do: %{state | retry: Process.send_after(self(), :retry, state.retry_ms)}

  defp retry_later(state), do: state
end

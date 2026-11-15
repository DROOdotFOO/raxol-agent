defmodule Raxol.Broker.Heartbeat do
  @moduledoc """
  The dead-man switch. Something a person runs has to beat within
  `dead_man_timeout` (the policy key; `:off` disables it): a mounted
  dashboard beats on every refresh, `mix raxol.broker.inspect` and
  `mix raxol.broker.beat` beat once.

  When a check finds no beat within the timeout, every strategy runner is
  paused (`{:pause, :dead_man}`; nothing is cancelled and the mode is left
  as it is) and a `halt` record with reason `dead_man_pause` is journaled.
  The next beat resumes them and journals `dead_man_resume`.

  Checks run every `:check_ms` (default the timeout, at most a minute).

  ## Options

  `:timeout` (required: milliseconds or `:off`), `:journal`, `:strategies`,
  `:clock` (zero-arity, monotonic milliseconds), `:schedule` (a one-arity
  function given the delay to the next check; default sends `:check` to
  this process after it), `:check_ms`, `:name` (default this module).
  """

  use GenServer

  alias Raxol.Broker.Journal
  alias Raxol.Broker.Strategy

  @max_check 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Record a beat from `source`; resumes runners the switch paused."
  @spec beat(GenServer.server(), String.t()) :: :ok
  def beat(server \\ __MODULE__, source) when is_binary(source),
    do: GenServer.call(server, {:beat, source})

  @doc "`%{paused: boolean, silent_ms: integer, timeout: ms | :off}`."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    me = self()
    timeout = Keyword.fetch!(opts, :timeout)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    state = %{
      timeout: timeout,
      journal: Keyword.get(opts, :journal, Journal),
      strategies: Keyword.get(opts, :strategies, Strategy.Supervisor),
      clock: clock,
      schedule: Keyword.get(opts, :schedule, fn ms -> Process.send_after(me, :check, ms) end),
      check_ms: Keyword.get(opts, :check_ms, check_ms(timeout)),
      last: clock.(),
      paused: false
    }

    if timeout != :off, do: state.schedule.(state.check_ms)
    {:ok, state}
  end

  defp check_ms(:off), do: @max_check
  defp check_ms(timeout), do: min(timeout, @max_check)

  @impl GenServer
  def handle_call({:beat, source}, _from, state) do
    if state.paused do
      Strategy.Supervisor.resume_all(:dead_man, supervisor: state.strategies)
      journal(state, %{"reason" => "dead_man_resume", "source" => source})
    end

    {:reply, :ok, %{state | last: state.clock.(), paused: false}}
  end

  def handle_call(:status, _from, state) do
    status = %{
      paused: state.paused,
      silent_ms: state.clock.() - state.last,
      timeout: state.timeout
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info(:check, %{timeout: :off} = state), do: {:noreply, state}

  def handle_info(:check, state) do
    silent = state.clock.() - state.last
    state.schedule.(state.check_ms)

    if silent >= state.timeout and not state.paused do
      Strategy.Supervisor.pause_all(:dead_man, supervisor: state.strategies)
      journal(state, %{"reason" => "dead_man_pause", "silent_ms" => silent})
      {:noreply, %{state | paused: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp journal(state, fields) do
    _ = Journal.record_halt(fields, state.journal)
    :ok
  end
end

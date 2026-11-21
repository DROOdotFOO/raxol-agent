defmodule Raxol.Broker.DailyBaseline do
  @moduledoc """
  Captures the account's live USD `total_value` only in the first 60 seconds
  of a New York day. Both the start and completion of the read must fall in
  that window. Missing it leaves baseline-dependent orders denied all day;
  the first drawdown-policy evaluation also disarms and pauses strategies.
  Capture on a later day does not resume or arm them automatically.

  The journal is authoritative: an existing account/day capture is never
  refreshed, including after restart. Reads use the read-only MCP client in
  a monitored process, not the executor's port. Failed reads get at most
  three attempts within the window.

  Options: `:journal`, `:client`, `:account` (required), `:clock` (UTC
  DateTime, default utc_now), `:schedule` (delay in milliseconds; default
  sends `:capture`), and `:name`.
  """
  use GenServer

  require Logger

  alias Raxol.Broker.{AccountPin, Clock, Journal, MarketCalendar, Response}
  alias Raxol.Broker.Journal.Codec
  alias Raxol.Broker.MCP.Client

  @timeout 5_000
  @retry 1_000
  @attempts 3

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    me = self()

    state = %{
      journal: Keyword.get(opts, :journal, Journal),
      client: Keyword.get(opts, :client, Client),
      account: Keyword.fetch!(opts, :account),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      schedule: Keyword.get(opts, :schedule, fn ms -> Process.send_after(me, :capture, ms) end),
      task: nil,
      day: nil,
      attempts: 0,
      last: nil,
      due: nil
    }

    {:ok, state, {:continue, :capture}}
  end

  @impl GenServer
  def handle_continue(:capture, state), do: {:noreply, capture(state)}

  @impl GenServer
  def handle_info(:capture, %{task: nil} = state), do: {:noreply, capture(state)}
  def handle_info(:capture, state), do: {:noreply, state}

  def handle_info({:baseline_read, pid, result}, %{task: {pid, ref, started}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case Clock.now(state.clock) do
      {:ok, now} ->
        result =
          with {:ok, value, observed} <- result,
               true <- DateTime.compare(observed, started) != :lt,
               true <- DateTime.compare(now, observed) != :lt do
            Journal.record_day_baseline(
              %{
                account: state.account,
                day_start: state.day,
                value: value,
                currency: "USD",
                request_started_at: started,
                observed_at: observed
              },
              state.journal
            )
          else
            _invalid -> {:error, :invalid_observation}
          end

        case result do
          :ok -> {:noreply, tomorrow(%{state | last: now}, now)}
          {:error, reason} -> {:noreply, failed(state, now, reason)}
        end

      {:error, reason} ->
        {:noreply, clock_failed(state, reason)}
    end
  catch
    :exit, reason -> {:stop, {:journal_unavailable, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{task: {pid, ref, _}} = state) do
    state = %{state | task: nil}

    case Clock.now(state.clock) do
      {:ok, now} -> {:noreply, failed(state, now, {:read_down, reason})}
      {:error, clock_error} -> {:noreply, clock_failed(state, {:read_down, reason, clock_error})}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{task: {pid, ref, _started}}) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp capture(state) do
    case Clock.now(state.clock) do
      {:ok, now} -> capture_at(state, now)
      {:error, reason} -> clock_failed(state, reason)
    end
  end

  defp capture_at(state, now) do
    day = MarketCalendar.day_start(now)
    state = if state.day == day, do: state, else: %{state | day: day, attempts: 0}

    cond do
      state.last && DateTime.compare(now, state.last) == :lt -> tomorrow(state, now)
      state.due && DateTime.compare(now, state.due) == :lt -> schedule(state, now, state.due)
      true -> maybe_read(%{state | last: now}, now, day)
    end
  end

  defp maybe_read(state, now, day) do
    case Journal.day_baseline(state.account, day, state.journal) do
      {:ok, %Decimal{}} ->
        tomorrow(state, now)

      {:ok, nil} ->
        if Codec.capture_window?(day, now) and state.attempts < @attempts do
          owner = self()

          {pid, ref} =
            spawn_monitor(fn -> send(owner, {:baseline_read, self(), fetch(state)}) end)

          %{state | task: {pid, ref, now}, attempts: state.attempts + 1}
        else
          tomorrow(state, now)
        end

      {:error, reason} ->
        failed(state, now, reason)
    end
  end

  defp fetch(state) do
    with :ok <- AccountPin.check(read(state.client, "get_accounts", %{}), state.account),
         {:ok, body} <- read(state.client, "get_portfolio", %{"account_number" => state.account}),
         {:ok, value} <- Codec.portfolio_value(body),
         {:ok, observed} <- Clock.now(state.clock) do
      {:ok, value, observed}
    end
  catch
    :exit, reason -> {:error, {:client_unavailable, reason}}
  end

  defp read(client, name, args), do: Response.body(Client.call(client, name, args, @timeout))

  defp clock_failed(state, reason) do
    Logger.warning("[Broker.DailyBaseline] clock refused: #{inspect(reason, structs: false)}")
    state.schedule.(@retry)
    state
  end

  defp failed(state, now, reason) do
    Logger.warning("[Broker.DailyBaseline] capture refused: #{inspect(reason, structs: false)}")
    next = DateTime.add(now, @retry, :millisecond)

    if state.attempts < @attempts and Codec.capture_window?(state.day, next) and
         (is_nil(state.last) or DateTime.compare(now, state.last) != :lt) do
      schedule(%{state | last: now}, now, next)
    else
      tomorrow(state, now)
    end
  end

  defp tomorrow(state, now) do
    # Noon of the next local date is safely beyond either DST transition;
    # day_start then resolves that date's actual midnight (23/25 hour days).
    next =
      now |> MarketCalendar.day_start() |> DateTime.add(36 * 3600) |> MarketCalendar.day_start()

    schedule(state, now, next)
  end

  defp schedule(state, now, due) do
    remaining_us = max(DateTime.diff(due, now, :microsecond), 0)
    state.schedule.(div(remaining_us + 999, 1000))
    %{state | due: due}
  end
end

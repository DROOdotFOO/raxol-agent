defmodule Raxol.Broker.HaltRequest do
  @moduledoc """
  Owner-only, halt-only mailbox for another OS process. An empty 0600
  `halt.request` in the private journal directory requests a kill. Presence
  blocks arming and sending immediately, independently of the polling worker.
  The supervisor polls every 100 ms; submission is not cancellation proof.
  No credentials, node cookies, identities or executable payloads cross it.
  """
  use GenServer

  require Logger
  import Bitwise, only: [band: 2]

  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.{Executor, Halt, Mode}

  @interval 100

  def path(journal_path), do: Path.join(journal_path, "halt.request")

  # Any unreadable marker blocks new orders, but only a trusted one authorizes
  # the worker to send cancels and declines.
  def pending?(path) do
    case File.lstat(path) do
      {:error, :enoent} -> false
      _exists_or_unreadable -> true
    end
  end

  @spec request(Path.t()) :: :ok | {:error, term()}
  def request(journal_path) do
    marker = path(journal_path)

    with :ok <- directory(journal_path) do
      case File.open(marker, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          result =
            with :ok <- File.chmod(marker, 0o600),
                 :ok <- :file.sync(io),
                 do: trusted(marker)

          closed = File.close(io)
          if result == :ok, do: closed, else: result

        {:error, :eexist} ->
          trusted(marker)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    marker = opts |> Keyword.fetch!(:path) |> path()

    state = %{
      marker: marker,
      opts: Keyword.delete(opts, :path),
      task: nil,
      disarmed: false,
      refusal: nil,
      retry_after: System.monotonic_time(:millisecond)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    state =
      cond do
        not pending?(state.marker) ->
          %{state | disarmed: false, refusal: nil}

        System.monotonic_time(:millisecond) < state.retry_after ->
          state

        true ->
          case trusted(state.marker) do
            :ok -> start_waiter(state)
            {:error, reason} -> refused(state, reason)
          end
      end

    Process.send_after(self(), :poll, @interval)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @interval)
    {:noreply, state}
  end

  def handle_info(
        {:halt_result, token, {:ok, summary}},
        %{task: %{ref: ref, token: token}} = state
      ) do
    Process.demonitor(ref, [:flush])

    # A not-ready executor has cancelled nothing. Retain the request until it
    # connects; after an attempted kill, errors remain in the halt journal.
    if summary.disarmed == :ok and summary.orders != {:error, :port_not_ready} do
      case File.rm(state.marker) do
        :ok -> :ok
        {:error, reason} -> Logger.error("broker halt request cleanup failed: #{inspect(reason)}")
      end
    end

    {:noreply, %{state | task: nil}}
  end

  def handle_info(
        {:halt_result, token, {:retry, reason}},
        %{task: %{ref: ref, token: token}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = refused(state, {:waiting_for_executor, reason})
    {:noreply, %{state | task: nil, retry_after: System.monotonic_time(:millisecond) + 1_000}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Logger.error("broker halt request worker failed: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  @impl true
  def terminate(_reason, %{task: task}) do
    if task, do: Process.exit(task.pid, :kill)
    :ok
  end

  defp start_waiter(state) do
    disarmed =
      if state.disarmed,
        do: :ok,
        else: Mode.disarm("kill", journal: state.opts[:journal], by: "local-halt-file")

    case disarmed do
      :ok ->
        parent = self()
        token = make_ref()

        {pid, ref} =
          spawn_monitor(fn ->
            send(parent, {:halt_result, token, wait_and_kill(state.opts)})
          end)

        %{state | disarmed: true, refusal: nil, task: %{pid: pid, ref: ref, token: token}}

      {:error, reason} ->
        refused(state, {:disarm_failed, reason})
    end
  end

  defp wait_and_kill(opts) do
    case Executor.await_port(Keyword.fetch!(opts, :executor), 5_000) do
      :ok -> Halt.kill(Keyword.put(opts, :trigger, "local-halt-file"))
      {:error, reason} -> {:retry, reason}
    end
  catch
    :exit, reason -> {:retry, {:executor_down, reason}}
  end

  defp refused(state, {:waiting_for_executor, reason} = failure) do
    if state.refusal != failure,
      do:
        Logger.warning(
          "broker halt request waiting for executor: #{inspect(reason, structs: false)}"
        )

    %{state | refusal: failure}
  end

  defp refused(state, reason) do
    if state.refusal != reason do
      Logger.error(
        "broker halt request refused: #{inspect(reason, structs: false)}; " <>
          "check #{state.marker}: expected an empty owner-only regular file, mode 0600"
      )
    end

    %{state | refusal: reason}
  end

  defp trusted(marker) do
    with :ok <- directory(Path.dirname(marker)),
         {:ok, %File.Stat{type: :regular, size: 0, mode: mode, uid: uid}} <- File.lstat(marker),
         true <- uid == OperatorFile.uid() and band(mode, 0o777) == 0o600 do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :untrusted_halt_request}
    end
  end

  defp directory(path) do
    with {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} <- File.lstat(path),
         true <- is_integer(uid) and uid == OperatorFile.uid() and band(mode, 0o077) == 0 do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :untrusted_halt_directory}
    end
  end
end

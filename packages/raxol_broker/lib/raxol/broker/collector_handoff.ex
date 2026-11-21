defmodule Raxol.Broker.CollectorHandoff do
  @moduledoc """
  Owner-only cooperative drain for a read-only collector, before OS unload.

  The caller handles SIGUSR2 in its own process and calls `quiesce/3`.
  Publish `handoff_protocol: 1` only when that handler is installed. No signal
  alone authorizes shutdown: an owner-held request must target this OS PID
  and carry an unexpired deadline and nonce. The collector remains alive
  after acknowledgement so launchd cannot restart it before unload.
  The root must be directly owned, without an external supervisor restarting it.
  """

  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.{DailyBaseline, HaltRequest, Journal, Mode}
  alias Raxol.Broker.MCP.Client
  require Logger

  @allowed [Client, Journal, DailyBaseline, HaltRequest]

  @spec quiesce(Path.t(), pid(), keyword()) :: :quiesced | :blocked | :ignored
  def quiesce(directory, root, opts \\ []) do
    with {:ok, request} <- request(directory) do
      client = Keyword.get(opts, :client, Client)
      journal = Keyword.get(opts, :journal, Journal)

      status =
        try do
          drain(root, client, journal)
        catch
          :exit, _reason -> :blocked
        end

      publish(directory, request, status)
      status
    else
      _invalid -> :ignored
    end
  end

  @doc """
  Bound the drained caller's wait if its controller disappears.

  Call only after `quiesce/3` returns `:quiesced`. The acknowledgement carries
  the original request deadline; eleven extra minutes cover the controller's
  maximum recovery budget and launchd operations. Missing/unreadable proof
  exits immediately: the client and journal have already stopped.
  """
  @spec wait_for_unload(Path.t()) :: no_return()
  def wait_for_unload(directory) do
    path = Path.join(directory, "handoff-quiesced.json")

    timeout =
      with :ok <- OperatorFile.trusted?(path),
           {:ok, %{size: size}} when size <= 4096 <- File.lstat(path),
           {:ok, data} <- File.read(path),
           {:ok, %{"status" => "quiesced", "process_id" => pid, "deadline" => deadline}} <-
             Jason.decode(data),
           true <- pid == System.pid(),
           true <- is_binary(deadline),
           {:ok, until, _offset} <- DateTime.from_iso8601(deadline) do
        max(DateTime.diff(until, DateTime.utc_now(), :millisecond) + 660_000, 0)
      else
        _invalid -> 0
      end

    receive do
    after
      timeout -> exit(:collector_handoff_abandoned)
    end
  end

  defp request(directory) do
    path = Path.join(directory, "handoff-request.json")

    with :ok <- OperatorFile.trusted?(path),
         {:ok, %{size: size, mode: mode}} when size <= 4096 <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, data} <- File.read(path),
         {:ok, %{"process_id" => pid, "nonce" => nonce, "deadline" => deadline} = request} <-
           Jason.decode(data),
         true <- pid == System.pid(),
         true <-
           is_binary(nonce) and byte_size(nonce) == 48 and String.match?(nonce, ~r/\A[0-9a-f]+\z/),
         true <- is_binary(deadline),
         {:ok, until, _offset} <- DateTime.from_iso8601(deadline),
         :lt <- DateTime.compare(DateTime.utc_now(), until) do
      {:ok, request}
    else
      _invalid -> {:error, :untrusted_or_expired_request}
    end
  end

  defp drain(root, client, journal) do
    children = Supervisor.which_children(root)

    if Enum.all?(children, fn {_id, _pid, _kind, modules} ->
         is_list(modules) and modules != [] and Enum.all?(modules, &(&1 in @allowed))
       end) do
      client_pid = GenServer.whereis(client)
      journal_pid = GenServer.whereis(journal)

      try do
        :ok = :sys.suspend(root, 5_000)

        if is_pid(client_pid) and GenServer.whereis(client) == client_pid and
             owns?(children, client_pid, Client) and owns?(children, journal_pid, Journal) do
          try do
            :ok = :sys.suspend(client_pid, 5_000)
            state = :sys.get_state(client_pid, 5_000)

            if state.status == :ready and is_nil(state.unpersisted) and
                 Mode.current(journal) == :disarmed do
              :ok = Supervisor.stop(root, :normal, :infinity)
              :quiesced
            else
              :blocked
            end
          after
            resume(client_pid)
          end
        else
          :blocked
        end
      after
        resume(root)
      end
    else
      :blocked
    end
  end

  defp resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid, 5_000)
  end

  defp owns?(children, pid, module) do
    Enum.any?(children, fn {_id, child, _kind, modules} ->
      child == pid and is_list(modules) and module in modules
    end)
  end

  defp publish(directory, request, status) do
    path = Path.join(directory, "handoff-quiesced.json")

    document = %{
      process_id: System.pid(),
      nonce: request["nonce"],
      deadline: request["deadline"],
      status: Atom.to_string(status),
      observed_at: DateTime.to_iso8601(DateTime.utc_now()),
      client_stopped: status == :quiesced,
      journal_closed: status == :quiesced
    }

    with :ok <- File.write(path <> ".tmp", Jason.encode!(document), [:exclusive]),
         :ok <- File.chmod(path <> ".tmp", 0o600),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      {:error, _reason} ->
        Logger.error(
          "[Broker.CollectorHandoff] acknowledgement could not be published; no OS unload is permitted"
        )
    end
  end
end

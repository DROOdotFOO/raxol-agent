defmodule Raxol.Payments.Ramp.Peer.Mapping do
  @moduledoc """
  Provider-private durable deposit/order mapping, separate from checkpoints.

  Start under a supervisor with a fixed DETS `:name` and private `:path`.
  Only protocol identifiers and atomic totals are retained; never credentials,
  payees, raw responses, unsigned calldata, signatures or proof material.
  The containing directory must be accessible only to the runtime user.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def fetch(server, operation), do: GenServer.call(server, {:fetch, operation})
  def put(server, operation, value), do: GenServer.call(server, {:put, operation, value})

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    with :ok <- private_directory(Path.dirname(path)),
         {:ok, table} <- :dets.open_file(Keyword.fetch!(opts, :name), file: to_charlist(path)),
         :ok <- File.chmod(path, 0o600) do
      {:ok, table}
    else
      _ -> {:stop, :mapping_unavailable}
    end
  end

  defp private_directory(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0, do: :ok, else: {:error, :insecure_mapping_path}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)

      _ ->
        {:error, :mapping_unavailable}
    end
  end

  @impl true
  def handle_call({:fetch, operation}, _from, table) do
    result =
      case :dets.lookup(table, operation) do
        [{^operation, value}] -> {:ok, value}
        [] -> :error
      end

    {:reply, result, table}
  end

  def handle_call({:put, operation, value}, _from, table) do
    clean = Map.take(value, [:deposit_id, :order_id, :total])
    result = with :ok <- :dets.insert(table, {operation, clean}), do: :dets.sync(table)
    {:reply, result, table}
  end

  @impl true
  def terminate(_, table), do: :dets.close(table)
end

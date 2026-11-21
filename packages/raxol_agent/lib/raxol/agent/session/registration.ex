defmodule Raxol.Agent.Session.Registration do
  @moduledoc false
  # Session keys in `Raxol.Agent.Registry`: the `{:session, session_id}` key
  # that `Raxol.Agent.Session.Supervisor.whereis/1` resolves, session id
  # minting, and waiting out a dead predecessor's key before a restart.

  require Logger

  @registry Raxol.Agent.Registry
  @attempts 200
  @retry_ms 5

  @doc """
  Block until `key` is unregistered, at most `attempts` × 5 ms.

  Registry removes a dead process's keys asynchronously, so a same-name
  restart can otherwise fail with `{:already_started, dead_pid}`. A key that
  is still held after the budget falls through to a normal start.
  """
  @spec await_free(term(), non_neg_integer()) :: :ok
  def await_free(key, attempts \\ @attempts) do
    case safe_lookup(key) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(@retry_ms)
        await_free(key, attempts - 1)

      _ ->
        :ok
    end
  end

  @doc """
  A session id for agent `id`: a filename-safe form of `id` plus a random
  suffix. It names the journal directory, so it must not collide with one an
  earlier BEAM left behind (`System.unique_integer/1` restarts per BEAM).
  """
  @spec derive_session_id(term()) :: String.t()
  def derive_session_id(id) do
    base =
      id
      |> to_id_string()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.trim("-")

    base = if base == "", do: "agent", else: base
    "#{base}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
  end

  @doc """
  Register the calling process under `{:session, session_id}`.

  A stale key from a dead predecessor is retried until it clears. A key
  still held by a live process after the budget is skipped with a warning
  and a `[:raxol, :agent, :session, :register_timeout]` event: the session
  runs, but cannot be found by session id.
  """
  @spec register(String.t(), term(), module(), term()) :: :ok
  def register(session_id, id, app_module, team_id) do
    if Process.whereis(@registry) do
      do_register({:session, session_id}, %{id: id, app_module: app_module, team_id: team_id})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp do_register(key, meta, attempts \\ @attempts) do
    case Registry.register(@registry, key, meta) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, {:already_registered, _pid}} when attempts > 0 ->
        Process.sleep(@retry_ms)
        do_register(key, meta, attempts - 1)

      {:error, {:already_registered, holder}} ->
        Logger.warning(
          "[Agent.Session] #{inspect(key)} is held by #{inspect(holder)}; running " <>
            "unregistered, so whereis/list_sessions/stop_session cannot find this session"
        )

        :telemetry.execute(
          [:raxol, :agent, :session, :register_timeout],
          %{count: 1},
          Map.put(meta, :key, key)
        )

        :ok
    end
  end

  @doc "The pid registered under `key`, or nil."
  @spec lookup(term()) :: pid() | nil
  def lookup(key) do
    case safe_lookup(key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp safe_lookup(key) do
    Registry.lookup(@registry, key)
  rescue
    ArgumentError -> []
  end

  defp to_id_string(id) when is_binary(id), do: id
  defp to_id_string(id) when is_atom(id), do: Atom.to_string(id)
  defp to_id_string(id), do: inspect(id)
end

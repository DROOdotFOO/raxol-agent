defmodule Raxol.CLI.Updater do
  @moduledoc """
  Version checks and verified self-update for a Burrito-packaged binary.

  Where updates come from is a `Raxol.CLI.Updater.Manifest`: by default the
  `raxol` CLI release channel (`raxol-cli-v*` releases on
  `DROOdotFOO/raxol-agent`), or whatever an application sets in
  `config :raxol_cli, :updater_manifest`.
  Every download is checked against the release's `SHA256SUMS` and, unless
  the manifest sets `provenance: :off`, against the release's Sigstore
  attestation (`Raxol.CLI.Updater.Provenance`: signed by the manifest's
  workflow for that tag) before it is extracted or installed. The replaced
  executable is kept so `rollback_update/1` can restore it.

  Nothing here runs a process of its own except `start_update/1`, which
  runs one update in a task the caller owns and can cancel.

  ## Options

  Every function takes a keyword list; each option defaults to the running
  installation:

    * `:manifest` - a `Manifest` struct or overrides of the configured one
    * `:force` - check even when the automatic-check interval has not passed
    * `:version` - for `check_for_updates/1`, check that release instead of the newest
    * `:current_version` - the installed version (default: the manifest's `:app`)
    * `:current_executable` - the binary to replace (default: the Burrito binary)
    * `:platform` - the manifest platform key (default: the host's)
    * `:settings_path` - the settings file (default: `~/.raxol/update_settings.json`)
    * `:backup_dir`, `:download_dir` - default to the settings' paths
    * `:work_dir` - scratch directory (default: a fresh temp dir, removed after)
  """

  alias Raxol.CLI.Updater.{Core, State}

  @type result :: :ok | {:no_update, String.t()} | {:error, term()}

  @typedoc "An update running in a task linked to the process that started it."
  @opaque in_flight :: %{task: Task.t(), work_dir: Path.t(), owns_work_dir?: boolean()}

  @spec get_update_settings(keyword()) :: State.t()
  def get_update_settings(opts \\ []), do: opts |> State.path() |> State.load()

  @spec set_update_settings(State.t(), keyword()) :: :ok | {:error, File.posix()}
  def set_update_settings(%State{} = settings, opts \\ []),
    do: State.save(settings, State.path(opts))

  @spec default_update_settings() :: State.t()
  def default_update_settings, do: State.new()

  @doc "Enables or disables automatic update checks."
  @spec set_auto_check(boolean(), keyword()) :: :ok | {:error, File.posix()}
  def set_auto_check(enabled, opts \\ []) when is_boolean(enabled) do
    path = State.path(opts)
    path |> State.load() |> State.set_auto_check(enabled) |> State.save(path)
  end

  @doc """
  Checks whether a newer release than the installed version is published.

  Without `force: true` this only goes to the network when automatic checks
  are enabled and the check interval has passed, and records the check time.

  Returns `{:update_available, version}`, `{:no_update, current_version}`,
  or `{:error, reason}`.
  """
  @spec check_for_updates(keyword()) ::
          {:update_available, String.t()} | {:no_update, String.t()} | {:error, term()}
  def check_for_updates(opts \\ []), do: Core.check(opts)

  @doc """
  Updates the running binary to `version` (default: the newest release),
  when that release is newer than the installed one.

  Returns `:ok`, `{:no_update, current_version}`, or `{:error, reason}`.
  Nothing is installed unless its checksum matches the release's
  `SHA256SUMS` and, with provenance required, the release's attestation
  covers it; a provenance failure is `{:error, {:provenance_failed, reason}}`.
  """
  @spec self_update(String.t() | nil, keyword()) :: result()
  def self_update(version \\ nil, opts \\ []), do: Core.self_update(version, opts)

  @doc "`self_update/2` to `opts[:version]`, else to whatever `check_for_updates/1` finds."
  @spec update(keyword() | map()) :: result()
  def update(opts \\ []), do: Core.update(opts)

  @doc """
  Runs `update/1` in a task linked to the caller, for `await_update/2` or
  `cancel_update/1`; only the process that started it may call either.
  Without `:work_dir` the update gets a fresh private scratch directory,
  removed when it is awaited or cancelled.
  """
  @spec start_update(keyword()) :: {:ok, in_flight()} | {:error, File.posix()}
  def start_update(opts \\ []) do
    with {:ok, work_dir, owns?} <- work_dir(opts) do
      task = Task.async(Core, :update, [Keyword.put(opts, :work_dir, work_dir)])
      {:ok, %{task: task, work_dir: work_dir, owns_work_dir?: owns?}}
    end
  end

  @doc """
  Waits up to `timeout` for an update from `start_update/1` and returns its
  result. An update still running at the timeout is stopped, as by
  `cancel_update/1`, and the result is `{:error, :timeout}`.
  """
  @spec await_update(in_flight(), timeout()) :: result() | {:error, :timeout}
  def await_update(%{task: task} = in_flight, timeout \\ :infinity) do
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  after
    remove_work_dir(in_flight)
  end

  @doc """
  Stops an update from `start_update/1`. `:cancelled` when it was still
  running, else `{:finished, result}` with the result it already had.

  The executable is replaced by a single rename, so a cancelled update
  leaves either the old binary or the new one in place, never a mix. On
  Windows the swap is handed to a script that runs after a short delay;
  a cancel that lands after that hand-off does not stop it.
  """
  @spec cancel_update(in_flight()) :: :cancelled | {:finished, result()}
  def cancel_update(%{task: task} = in_flight) do
    case Task.shutdown(task) do
      nil -> :cancelled
      {:ok, result} -> {:finished, result}
      {:exit, reason} -> {:finished, {:error, {:exit, reason}}}
    end
  after
    remove_work_dir(in_flight)
  end

  @doc "Downloads and verifies a release asset; see `install_update/3`."
  @spec download_update(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def download_update(version, opts \\ []), do: Core.download_update(version, opts)

  @doc "Re-verifies and installs an asset fetched by `download_update/2`."
  @spec install_update(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def install_update(context, version, opts \\ []),
    do: Core.install_update(context, version, opts)

  @doc "Restores the executable the last install replaced."
  @spec rollback_update(keyword()) :: :ok | {:error, term()}
  def rollback_update(opts \\ []), do: Core.rollback_update(opts)

  @spec get_current_version(keyword()) :: String.t() | nil
  def get_current_version(opts \\ []), do: Core.get_current_version(opts)

  @doc """
  The executable an update would replace: `:current_executable`, else the
  Burrito binary this node runs from; `{:error, :not_running_as_binary}` on a
  plain `mix`/`iex` node.
  """
  @spec current_executable(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def current_executable(opts \\ []), do: Core.current_executable(opts)

  @spec get_available_versions(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_available_versions(opts \\ []), do: Core.get_available_versions(opts)

  @doc "Prints a notice when `check_for_updates/1` finds a newer release."
  @spec notify_if_update_available(keyword()) :: :ok
  def notify_if_update_available(opts \\ []), do: Core.notify_if_update_available(opts)

  defp work_dir(opts) do
    case Keyword.fetch(opts, :work_dir) do
      {:ok, dir} -> {:ok, dir, false}
      :error -> with {:ok, dir} <- Core.fresh_work_dir(), do: {:ok, dir, true}
    end
  end

  defp remove_work_dir(%{owns_work_dir?: true, work_dir: dir}), do: File.rm_rf(dir)
  defp remove_work_dir(%{owns_work_dir?: false}), do: :ok
end

defmodule Raxol.CLI.Updater.Core do
  @moduledoc """
  The update flow behind `Raxol.CLI.Updater`.

  Every install follows one order: resolve the release from the manifest,
  fetch its `SHA256SUMS` and (unless the manifest turns provenance off) its
  Sigstore attestation, download, verify the download's checksum, verify
  the attestation covers the download (`Raxol.CLI.Updater.Provenance`),
  and only then extract (archive channels) and install. Nothing downloaded
  is extracted, executed, or copied over the running binary before it
  verifies, and a release whose attestation is missing or does not verify
  is never installed.

  Functions take the options documented on `Raxol.CLI.Updater`; each
  defaults to the running installation.
  """
  alias Raxol.CLI.Updater.{
    Archive,
    Manifest,
    Network,
    Provenance,
    State,
    Validation
  }

  alias Raxol.CLI.Updater.Provenance.Policy

  @spec check(keyword()) ::
          {:update_available, String.t()}
          | {:no_update, String.t()}
          | {:error, term()}
  def check(opts \\ []) do
    with {:ok, manifest} <- Manifest.load(opts),
         {:ok, current} <- current_version(manifest, opts) do
      if Keyword.get(opts, :force) == true or check_due?(opts),
        do:
          compare_release(
            manifest,
            Keyword.get(opts, :version) || :latest,
            current
          ),
        else: {:no_update, current}
    end
  end

  @spec self_update(String.t() | nil, keyword()) ::
          :ok | {:no_update, String.t()} | {:error, term()}
  def self_update(version \\ nil, opts \\ []) do
    with {:ok, ctx} <- resolve(version || :latest, opts),
         {:ok, current} <- current_version(ctx.manifest, opts) do
      if Validation.newer?(ctx.release.version, current),
        do: install(ctx, opts),
        else: {:no_update, current}
    end
  end

  @doc """
  Downloads and verifies the release asset for `version` into the download
  directory, where `install_update/3` picks it up.
  """
  @spec download_update(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def download_update(version, opts \\ []) do
    with {:ok, ctx} <- resolve(version, opts),
         {:ok, asset} <- asset_checksum(ctx),
         {:ok, attestation} <- fetch_attestation(ctx),
         {:ok, _path} <-
           download_verified(ctx, asset, attestation, download_dir(opts)) do
      {:ok, ctx.release.version}
    end
  end

  @doc """
  Installs a release previously fetched by `download_update/2`. The stored
  file is re-verified against the release's `SHA256SUMS` and attestation
  first, so a file swapped in the download directory in between is refused.
  """
  @spec install_update(map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def install_update(context, version, opts \\ []) do
    with {:ok, ctx} <- resolve(version, opts),
         {:ok, path} <- stored_download(ctx, opts),
         {:ok, current_exe} <- context_executable(context, opts),
         :ok <-
           with_work_dir(
             opts,
             &stage_and_install(ctx, path, current_exe, &1, opts)
           ) do
      {:ok, ctx.release.version}
    end
  end

  @doc "Restores the executable saved by the last install."
  @spec rollback_update(keyword()) :: :ok | {:error, term()}
  def rollback_update(opts \\ []) do
    backup = Path.join(backup_dir(opts), "previous_version")

    with {:ok, platform} <- platform(opts),
         {:ok, current_exe} <- current_executable(opts),
         true <- File.regular?(backup) || {:error, :no_backup_found} do
      Network.install_executable(current_exe, backup, nil, platform)
    end
  end

  @spec get_current_version(keyword()) :: String.t() | nil
  def get_current_version(opts \\ []) do
    with {:ok, manifest} <- Manifest.load(opts),
         {:ok, version} <- current_version(manifest, opts) do
      version
    else
      _ -> nil
    end
  end

  @spec get_available_versions(keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def get_available_versions(opts \\ []) do
    with {:ok, manifest} <- Manifest.load(opts),
         {:ok, latest} <- Network.fetch_release(manifest, :latest) do
      {:ok, [latest.version]}
    end
  end

  @spec update(keyword() | map()) ::
          :ok | {:no_update, String.t()} | {:error, term()}
  def update(opts \\ []) do
    opts = if is_map(opts), do: Enum.into(opts, []), else: opts

    case Keyword.get(opts, :version) do
      nil ->
        case check(opts) do
          {:update_available, version} -> self_update(version, opts)
          other -> other
        end

      version ->
        self_update(version, opts)
    end
  end

  @spec notify_if_update_available(keyword()) :: :ok
  def notify_if_update_available(opts \\ []) do
    case check(opts) do
      {:update_available, version} ->
        fg_hex =
          Raxol.Style.Colors.Color.from_rgb(0, 255, 0)
          |> Raxol.Style.Colors.Color.to_hex()

        bg_hex =
          Raxol.Style.Colors.Color.from_rgb(0, 0, 0)
          |> Raxol.Style.Colors.Color.to_hex()

        Raxol.UI.Terminal.println("Update Available! (#{version})",
          color: fg_hex,
          background: bg_hex
        )

        :ok

      _no_update_or_error ->
        :ok
    end
  end

  defp platform(opts) do
    case Keyword.fetch(opts, :platform) do
      {:ok, platform} -> {:ok, platform}
      :error -> Manifest.host_platform()
    end
  end

  defp current_version(manifest, opts) do
    case Keyword.fetch(opts, :current_version) do
      {:ok, version} -> Manifest.normalize_version(version)
      :error -> Manifest.installed_version(manifest)
    end
  end

  @doc """
  The executable to replace: `opts[:current_executable]`, else the Burrito
  binary this node was launched from. Nothing else qualifies -- a plain
  `mix`/`iex` node has no executable of its own to replace.
  """
  @spec current_executable(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def current_executable(opts) do
    case Keyword.get(opts, :current_executable) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> burrito_executable()
    end
  end

  defp with_work_dir(opts, fun) do
    case Keyword.fetch(opts, :work_dir) do
      {:ok, dir} ->
        with :ok <- File.mkdir_p(dir), do: fun.(dir)

      :error ->
        with {:ok, dir} <- fresh_work_dir() do
          try do
            fun.(dir)
          after
            File.rm_rf(dir)
          end
        end
    end
  end

  @doc """
  Creates a scratch directory under the system temp dir that nobody else
  can write to: a new, unguessable name, `0700`. A name that already
  exists is an error, never reused, so on a shared `/tmp` another user
  cannot stage files where a verified download is about to be copied from.
  """
  @spec fresh_work_dir() :: {:ok, Path.t()} | {:error, File.posix()}
  def fresh_work_dir do
    name = "raxol_update_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), name)

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    end
  end

  # Only the interval-gated (automatic) check reads and records the last
  # check time; a forced check neither consults nor resets it.
  defp check_due?(opts) do
    path = State.path(opts)
    settings = State.load(path)
    now = :os.system_time(:second)

    if State.check_due?(settings, now) do
      _ = settings |> State.checked(now) |> State.save(path)
      true
    else
      false
    end
  end

  defp compare_release(manifest, version, current) do
    with {:ok, release} <- Network.fetch_release(manifest, version) do
      Validation.compare_versions(current, release.version)
    end
  end

  # The manifest, platform, and release every update path starts from.
  defp resolve(version, opts) do
    with {:ok, manifest} <- Manifest.load(opts),
         {:ok, platform} <- platform(opts),
         {:ok, release} <- Network.fetch_release(manifest, version) do
      {:ok, %{manifest: manifest, platform: platform, release: release}}
    end
  end

  # Everything an install needs beyond `resolve/2`: the running executable,
  # the release's checksums, and where the old binary is kept.
  defp install(ctx, opts) do
    with {:ok, current_exe} <- current_executable(opts),
         {:ok, sums} <- Network.fetch_checksums(ctx.manifest, ctx.release) do
      plan =
        Map.merge(ctx, %{
          checksums: sums,
          current_exe: current_exe,
          backup_dir: backup_dir(opts)
        })

      with_work_dir(opts, &full_install(Map.put(plan, :work_dir, &1)))
    end
  end

  # The file `download_update/2` stored, re-verified against the release.
  defp stored_download(ctx, opts) do
    with {:ok, asset} <- asset_checksum(ctx),
         {:ok, attestation} <- fetch_attestation(ctx),
         path = Path.join(download_dir(opts), asset.name),
         :ok <- Network.verify_file(path, asset.sha, asset.name),
         :ok <-
           discard_on_error(path, verify_provenance(ctx, asset, attestation)) do
      {:ok, path}
    end
  end

  defp full_install(plan) do
    with {:ok, asset} <- asset_sha(plan, plan.checksums),
         {:ok, attestation} <- fetch_attestation(plan),
         {:ok, path} <-
           download_verified(plan, asset, attestation, plan.work_dir),
         {:ok, new_exe} <- stage(plan.manifest, path, plan.work_dir) do
      Network.install_executable(
        plan.current_exe,
        new_exe,
        plan.backup_dir,
        plan.platform
      )
    end
  end

  defp stage_and_install(ctx, verified, current_exe, work_dir, opts) do
    with {:ok, new_exe} <- stage(ctx.manifest, verified, work_dir) do
      Network.install_executable(
        current_exe,
        new_exe,
        backup_dir(opts),
        ctx.platform
      )
    end
  end

  defp asset_checksum(ctx) do
    with {:ok, sums} <- Network.fetch_checksums(ctx.manifest, ctx.release) do
      asset_sha(ctx, sums)
    end
  end

  # The platform's asset name and its SHA256SUMS entry. Resolved before any
  # download starts, so a release without a checksum is never fetched.
  defp asset_sha(ctx, sums) do
    with {:ok, name} <- Manifest.asset(ctx.manifest, ctx.platform),
         {:ok, sha} <- Network.checksum_for(sums, name) do
      {:ok, %{name: name, sha: sha}}
    end
  end

  defp download_verified(ctx, asset, attestation, dir) do
    path = Path.join(dir, asset.name)
    url = Manifest.asset_url(ctx.manifest, ctx.release.tag, asset.name)

    with :ok <- File.mkdir_p(dir),
         :ok <- Network.download(url, path),
         :ok <-
           discard_on_error(
             path,
             Network.verify_file(path, asset.sha, asset.name)
           ),
         :ok <-
           discard_on_error(path, verify_provenance(ctx, asset, attestation)) do
      {:ok, path}
    end
  end

  # The release's Sigstore bundle, fetched before the asset so that a
  # release without one is never downloaded. Missing is a refusal, not a
  # fallback to checksums alone.
  defp fetch_attestation(%{manifest: %Manifest{provenance: :off}}),
    do: {:ok, :off}

  defp fetch_attestation(ctx) do
    case Network.fetch_attestation(ctx.manifest, ctx.release) do
      {:ok, bundle} ->
        {:ok, bundle}

      {:error, reason} ->
        {:error, {:provenance_failed, {:attestation_unavailable, reason}}}
    end
  end

  # The checksum-verified asset must be an attested subject of a bundle the
  # manifest's signer workflow produced for this release's tag.
  defp verify_provenance(_ctx, _asset, :off), do: :ok

  defp verify_provenance(ctx, asset, bundle) do
    %Manifest{repo: repo, signer_workflow: workflow} = ctx.manifest
    policy = Policy.for_release(repo, workflow, ctx.release.tag)

    case Provenance.verify(bundle, {asset.name, {"sha256", asset.sha}}, policy) do
      {:ok, _verified} -> :ok
      {:error, reason} -> {:error, {:provenance_failed, reason}}
    end
  end

  # A verified asset becomes the executable to install: as-is for a raw
  # binary channel, or extracted (entry paths vetted) for an archive one.
  defp stage(%Manifest{format: :binary}, verified, _work_dir),
    do: {:ok, verified}

  defp stage(%Manifest{format: {kind, exe}}, verified, work_dir) do
    extract_dir = Path.join(work_dir, "extracted")

    with :ok <- Archive.extract(verified, extract_dir, kind) do
      Archive.find_executable(extract_dir, exe)
    end
  end

  defp discard_on_error(path, {:error, _reason} = error) do
    _ = File.rm(path)
    error
  end

  defp discard_on_error(_path, result), do: result

  defp context_executable(%{current_exe: path}, _opts)
       when is_binary(path) and path != "",
       do: {:ok, path}

  defp context_executable(_context, opts), do: current_executable(opts)

  defp backup_dir(opts) do
    Keyword.get_lazy(opts, :backup_dir, fn ->
      State.load(State.path(opts)).backup_path
    end)
  end

  defp download_dir(opts) do
    Keyword.get_lazy(opts, :download_dir, fn ->
      State.load(State.path(opts)).download_path
    end)
  end

  # Burrito's launcher exports the wrapped binary's path as
  # `__BURRITO_BIN_PATH`; `Burrito.Util.Args.get_bin_path/0` reads the same
  # variable. Reading it here keeps Burrito out of this library's deps.
  defp burrito_executable do
    case System.get_env("__BURRITO_BIN_PATH") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :not_running_as_binary}
    end
  end
end

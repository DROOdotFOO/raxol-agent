defmodule Raxol.CLI.UpdaterTest do
  @moduledoc """
  The self-updater against a real HTTP release channel on loopback: real
  downloads, real SHA256SUMS, real files standing in for the running
  executable. What is asserted is what would end up on disk.

  Synthetic binaries have no Sigstore attestation, so those channels turn
  provenance off; the "provenance" tests keep the default channel's
  `provenance: :required` and serve the real `raxol-cli-v0.2.10` bundle.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Raxol.CLI.Updater
  alias Raxol.CLI.Updater.{Archive, Manifest, State}
  alias Raxol.Test.UpdaterReleaseServer, as: Server

  @repo "DROOdotFOO/raxol-agent"
  # The repository whose release workflow signed the 0.2.10 fixture.
  @attested_repo "DROOdotFOO/raxol"
  @platform "linux-x64"
  @asset "raxol_cli_linux"
  @old "old binary"
  @attestation "raxol-cli-attestation.sigstore.json"
  @bundle Path.expand(
            "../../fixtures/sigstore/0.2.10/raxol-cli-attestation.sigstore.json",
            __DIR__
          )

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_updater_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    exe = Path.join(dir, "raxol")
    File.write!(exe, @old)

    %{
      dir: dir,
      exe: exe,
      backup: Path.join([dir, "backups", "previous_version"])
    }
  end

  defp opts(base, ctx, extra \\ []) do
    {manifest, extra} = Keyword.pop(extra, :manifest, [])

    Keyword.merge(
      [
        manifest:
          Keyword.merge(
            [api_base: base, download_base: base, provenance: :off],
            manifest
          ),
        platform: @platform,
        current_version: "1.0.0",
        current_executable: ctx.exe,
        backup_dir: Path.join(ctx.dir, "backups"),
        work_dir: Path.join(ctx.dir, "work")
      ],
      extra
    )
  end

  # The default channel's provenance policy, for the repository that signed
  # the fixture, on the loopback server.
  defp attested_opts(base, ctx, extra) do
    base
    |> opts(ctx, extra)
    |> Keyword.update!(:manifest, fn manifest ->
      manifest |> Keyword.delete(:provenance) |> Keyword.put(:repo, @attested_repo)
    end)
  end

  defp download_path(tag, name),
    do: "/#{@repo}/releases/download/#{tag}/#{name}"

  describe "manifest pinning" do
    test "the default channel builds every URL from the raxol-cli releases of DROOdotFOO/raxol-agent" do
      {:ok, manifest} = Manifest.load()
      {:ok, tag} = Manifest.tag(manifest, "v0.2.10")

      assert tag == "raxol-cli-v0.2.10"

      assert Manifest.release_url(manifest, tag) ==
               "https://api.github.com/repos/DROOdotFOO/raxol-agent/releases/tags/raxol-cli-v0.2.10"

      assert Manifest.asset_url(manifest, tag, @asset) ==
               "https://github.com/DROOdotFOO/raxol-agent/releases/download/raxol-cli-v0.2.10/raxol_cli_linux"
    end

    test "a version, repo, or base URL that could redirect a download is refused" do
      {:ok, manifest} = Manifest.load()

      assert {:error, {:invalid_version, _}} =
               Manifest.tag(manifest, "1.0.0/../../evil")

      assert {:error, {:invalid_version, _}} =
               Manifest.tag(manifest, "1.0.0-rc1")

      assert {:error, {:invalid_manifest, :api_base, _}} =
               Manifest.new(api_base: "http://evil.example")

      assert {:error, {:invalid_manifest, :download_base, _}} =
               Manifest.new(download_base: "https://github.com/someone-else")

      assert {:error, {:invalid_manifest, :repo, _}} =
               Manifest.new(repo: "a/b/../c")

      assert {:error, {:invalid_manifest, :assets, _}} =
               Manifest.new(assets: %{@platform => "../x"})

      assert {:error, {:unknown_manifest_keys, [:url]}} =
               Manifest.new(url: "https://x")

      assert {:ok, _loopback} = Manifest.new(api_base: "http://127.0.0.1:4000")
    end

    test "a provenance policy that is not a workflow of the channel's repo is refused" do
      assert {:error, {:invalid_manifest, :provenance, :optional}} =
               Manifest.new(provenance: :optional)

      assert {:error, {:invalid_manifest, :signer_workflow, _}} =
               Manifest.new(signer_workflow: "someone/else/.github/workflows/x.yml")

      assert {:error, {:invalid_manifest, :attestation_asset, _}} =
               Manifest.new(attestation_asset: "../bundle.json")
    end
  end

  describe "self_update/2 on a raw-binary channel" do
    test "installs the verified binary from the pinned URL, and rollback restores the old one",
         ctx do
      tag = "raxol-cli-v1.1.0"

      base =
        Server.start(Server.release_routes(@repo, tag, %{@asset => "new binary"}))

      assert :ok = Updater.self_update("1.1.0", opts(base, ctx))

      assert File.read!(ctx.exe) == "new binary"
      assert File.read!(ctx.backup) == @old

      asset_path = download_path(tag, @asset)
      assert_received {:release_request, ^asset_path}

      unless match?({:win32, _}, :os.type()) do
        assert (File.stat!(ctx.exe).mode &&& 0o111) != 0
      end

      assert :ok = Updater.rollback_update(opts(base, ctx))
      assert File.read!(ctx.exe) == @old
    end

    test "a binary that does not match SHA256SUMS is refused and nothing is replaced",
         ctx do
      tag = "raxol-cli-v1.1.0"
      sums = Server.sha256sums(%{@asset => "the binary that was published"})

      base =
        Server.start(
          Server.release_routes(@repo, tag, %{@asset => "a tampered binary"}, checksums: sums)
        )

      assert {:error, {:checksum_mismatch, @asset}} =
               Updater.self_update("1.1.0", opts(base, ctx))

      assert File.read!(ctx.exe) == @old
      refute File.exists?(ctx.backup)
    end

    test "without a usable SHA256SUMS entry the binary is never even downloaded",
         ctx do
      tag = "raxol-cli-v1.1.0"
      other = Server.sha256sums(%{"raxol_cli_macos" => "x"})
      sha = Server.sha256("new binary")

      for {sums, expected} <- [
            {other, {:missing_checksum, @asset}},
            {"#{sha}  #{@asset}\n#{sha}  #{@asset}\n", {:duplicate_checksum, @asset}},
            {"not a checksum line\n", {:invalid_checksum_line, "not a checksum line"}}
          ] do
        base =
          Server.start(
            Server.release_routes(@repo, tag, %{@asset => "new binary"}, checksums: sums)
          )

        assert {:error, ^expected} =
                 Updater.self_update("1.1.0", opts(base, ctx))

        asset_path = download_path(tag, @asset)
        refute_received {:release_request, ^asset_path}

        assert File.read!(ctx.exe) == @old
      end
    end

    test "an equal or older release is not installed", ctx do
      base =
        Server.start(Server.release_routes(@repo, "raxol-cli-v1.0.0", %{@asset => "same"}))

      assert {:no_update, "1.0.0"} =
               Updater.self_update("1.0.0", opts(base, ctx))

      assert File.read!(ctx.exe) == @old
    end
  end

  describe "check_for_updates/1" do
    test "reports the newest published release on the channel, ignoring other tags",
         ctx do
      listing = [
        Server.release_json("v9.0.0", %{}),
        Server.release_json("raxol-cli-v2.0.0", %{}, prerelease: true),
        Server.release_json("raxol-cli-v3.0.0", %{}, draft: true),
        Server.release_json("raxol-cli-v1.0.5", %{})
      ]

      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.1.0", %{@asset => "x"}, listing: listing)
        )

      assert {:update_available, "1.1.0"} =
               Updater.check_for_updates(opts(base, ctx, force: true))

      assert {:no_update, "1.1.0"} =
               Updater.check_for_updates(opts(base, ctx, force: true, current_version: "1.1.0"))
    end
  end

  describe "interval-gated checks" do
    setup ctx do
      %{settings: Path.join(ctx.dir, "update_settings.json")}
    end

    defp gated(base, ctx, extra \\ []),
      do: opts(base, ctx, Keyword.put(extra, :settings_path, ctx.settings))

    defp serve_1_1_0,
      do: Server.start(Server.release_routes(@repo, "raxol-cli-v1.1.0", %{@asset => "x"}))

    test "a due check goes to the network and records when it ran", ctx do
      base = serve_1_1_0()
      before = :os.system_time(:second)

      assert {:update_available, "1.1.0"} = Updater.check_for_updates(gated(base, ctx))
      assert_received {:release_request, _path}

      assert Updater.get_update_settings(settings_path: ctx.settings).last_check >= before
    end

    test "a check inside the interval answers without a request", ctx do
      base = serve_1_1_0()
      now = :os.system_time(:second)

      :ok =
        Updater.set_update_settings(%{State.new() | last_check: now}, settings_path: ctx.settings)

      assert {:no_update, "1.0.0"} = Updater.check_for_updates(gated(base, ctx))
      refute_received {:release_request, _path}
    end

    test "with automatic checks off only a forced check runs, and it records nothing", ctx do
      base = serve_1_1_0()
      assert :ok = Updater.set_auto_check(false, settings_path: ctx.settings)

      assert {:no_update, "1.0.0"} = Updater.check_for_updates(gated(base, ctx))
      refute_received {:release_request, _path}

      assert {:update_available, "1.1.0"} =
               Updater.check_for_updates(gated(base, ctx, force: true))

      settings = Updater.get_update_settings(settings_path: ctx.settings)
      refute settings.auto_check
      assert settings.last_check == nil
    end
  end

  describe "start_update/1" do
    test "await_update/2 returns the update's result", ctx do
      base = serve_1_1_0()

      {:ok, in_flight} = Updater.start_update(opts(base, ctx, version: "1.1.0"))

      assert :ok = Updater.await_update(in_flight)
      assert File.read!(ctx.exe) == "x"
    end

    test "cancel_update/1 stops an update in flight and leaves the binary alone", ctx do
      base = hanging_server()

      {:ok, in_flight} =
        base |> opts(ctx, force: true) |> Keyword.delete(:work_dir) |> Updater.start_update()

      assert_receive :connected, 5_000

      assert File.dir?(in_flight.work_dir)
      assert Updater.cancel_update(in_flight) == :cancelled
      refute Process.alive?(in_flight.task.pid)
      refute File.exists?(in_flight.work_dir)
      assert File.read!(ctx.exe) == @old
      refute File.exists?(ctx.backup)
    end

    test "await_update/2 stops an update that outlives its timeout", ctx do
      base = hanging_server()

      {:ok, in_flight} =
        base |> opts(ctx, force: true) |> Keyword.delete(:work_dir) |> Updater.start_update()

      assert_receive :connected, 5_000

      assert Updater.await_update(in_flight, 50) == {:error, :timeout}
      refute Process.alive?(in_flight.task.pid)
      refute File.exists?(in_flight.work_dir)
      assert File.read!(ctx.exe) == @old
    end

    test "the scratch directory it makes is private and new" do
      assert {:ok, dir} = Raxol.CLI.Updater.Core.fresh_work_dir()
      on_exit(fn -> File.rm_rf!(dir) end)

      assert File.ls!(dir) == []
      assert (File.stat!(dir).mode &&& 0o777) == 0o700
    end

    test "cancel_update/1 after the update finished hands back its result", ctx do
      base = serve_1_1_0()

      {:ok, in_flight} =
        Updater.start_update(opts(base, ctx, version: "1.1.0", current_version: "1.1.0"))

      %Task{pid: pid} = in_flight.task
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert Updater.cancel_update(in_flight) == {:finished, {:no_update, "1.1.0"}}
    end
  end

  # A loopback listener that accepts a connection and never answers, so a
  # request to it stays in flight until the requester is stopped.
  defp hanging_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listen)
    test = self()

    _acceptor =
      spawn_link(fn ->
        {:ok, _socket} = :gen_tcp.accept(listen)
        send(test, :connected)
        Process.sleep(:infinity)
      end)

    "http://127.0.0.1:#{port}"
  end

  defp tar_gz(path, entries) do
    {:ok, tar} = :erl_tar.open(to_charlist(path), [:write, :compressed])

    for {name, bytes} <- entries,
        do: :ok = :erl_tar.add(tar, bytes, to_charlist(name), [])

    :ok = :erl_tar.close(tar)
    File.read!(path)
  end

  defp archive_opts(base, ctx) do
    opts(base, ctx,
      manifest: [
        assets: %{@platform => "raxol.tar.gz"},
        format: {:tar_gz, "raxol"}
      ]
    )
  end

  describe "archive channels" do
    test "a verified archive installs the executable it contains", ctx do
      archive =
        tar_gz(Path.join(ctx.dir, "good.tar.gz"), [
          {"bin/raxol", "archived binary"}
        ])

      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.1.0", %{
            "raxol.tar.gz" => archive
          })
        )

      assert :ok = Updater.self_update("1.1.0", archive_opts(base, ctx))
      assert File.read!(ctx.exe) == "archived binary"
    end

    test "an entry escaping the extraction directory refuses the whole archive before extraction",
         ctx do
      archive =
        tar_gz(Path.join(ctx.dir, "evil.tar.gz"), [
          {"../evil", "pwned"},
          {"raxol", "payload"}
        ])

      base =
        Server.start(
          Server.release_routes(@repo, "raxol-cli-v1.1.0", %{
            "raxol.tar.gz" => archive
          })
        )

      assert {:error, {:unsafe_archive_entry, "../evil"}} =
               Updater.self_update("1.1.0", archive_opts(base, ctx))

      assert File.read!(ctx.exe) == @old
      refute File.exists?(Path.join([ctx.dir, "work", "evil"]))
      refute File.exists?(Path.join([ctx.dir, "work", "extracted", "raxol"]))
    end

    test "the checksum is checked before the archive is opened", ctx do
      archive =
        tar_gz(Path.join(ctx.dir, "evil.tar.gz"), [
          {"../evil", "pwned"},
          {"raxol", "payload"}
        ])

      sums =
        Server.sha256sums(%{"raxol.tar.gz" => "the archive that was published"})

      base =
        Server.start(
          Server.release_routes(
            @repo,
            "raxol-cli-v1.1.0",
            %{"raxol.tar.gz" => archive},
            checksums: sums
          )
        )

      assert {:error, {:checksum_mismatch, "raxol.tar.gz"}} =
               Updater.self_update("1.1.0", archive_opts(base, ctx))
    end

    test "a zip entry escaping the extraction directory is refused", ctx do
      zip = Path.join(ctx.dir, "evil.zip")

      {:ok, _} =
        :zip.create(to_charlist(zip), [
          {~c"../zevil", "pwned"},
          {~c"raxol", "x"}
        ])

      assert {:error, {:unsafe_archive_entry, "../zevil"}} =
               Archive.extract(zip, Path.join(ctx.dir, "zout"), :zip)

      refute File.exists?(Path.join(ctx.dir, "zevil"))
      refute File.exists?(Path.join([ctx.dir, "zout", "raxol"]))
    end

    # Creating a symlink needs a privilege Windows runners do not grant.
    @tag :skip_on_windows
    test "a tar symlink entry is refused", ctx do
      link_dir = Path.join(ctx.dir, "linked")
      File.mkdir_p!(link_dir)
      :ok = File.ln_s("/etc/passwd", Path.join(link_dir, "raxol"))
      tar = Path.join(ctx.dir, "link.tar.gz")
      {:ok, t} = :erl_tar.open(to_charlist(tar), [:write, :compressed])

      :ok =
        :erl_tar.add(
          t,
          to_charlist(Path.join(link_dir, "raxol")),
          ~c"raxol",
          []
        )

      :ok = :erl_tar.close(t)

      assert {:error, {:unsafe_archive_entry, "raxol", :symlink}} =
               Archive.extract(tar, Path.join(ctx.dir, "tout"), :tar_gz)
    end
  end

  @attested_tag "raxol-cli-v0.2.10"

  # The real raxol-cli-v0.2.10 attestation serves beside binaries it does not
  # cover: every Sigstore check passes except the subject digest.
  defp serve_attested(assets) do
    Server.start(Server.release_routes(@attested_repo, @attested_tag, assets))
  end

  describe "provenance" do
    test "a binary the release's attestation does not cover is refused and nothing is replaced",
         ctx do
      base =
        serve_attested(%{
          @asset => "new binary",
          @attestation => File.read!(@bundle)
        })

      assert {:error, {:provenance_failed, {:subject_digest_mismatch, @asset}}} =
               Updater.self_update(
                 "0.2.10",
                 attested_opts(base, ctx, current_version: "0.2.8")
               )

      assert File.read!(ctx.exe) == @old
      refute File.exists?(ctx.backup)
      refute File.exists?(Path.join([ctx.dir, "work", @asset]))
    end

    test "a release without an attestation is refused before its binary is downloaded",
         ctx do
      base = serve_attested(%{@asset => "new binary"})

      assert {:error, {:provenance_failed, {:attestation_unavailable, {:http_status, 404, _url}}}} =
               Updater.self_update(
                 "0.2.10",
                 attested_opts(base, ctx, current_version: "0.2.8")
               )

      asset_path = "/#{@attested_repo}/releases/download/#{@attested_tag}/#{@asset}"
      refute_received {:release_request, ^asset_path}
      assert File.read!(ctx.exe) == @old
    end

    test "download_update/2 and install_update/3 refuse what the attestation does not cover",
         ctx do
      base =
        serve_attested(%{
          @asset => "new binary",
          @attestation => File.read!(@bundle)
        })

      download_dir = Path.join(ctx.dir, "downloads")
      opts = attested_opts(base, ctx, download_dir: download_dir)
      stored = Path.join(download_dir, @asset)

      assert {:error, {:provenance_failed, {:subject_digest_mismatch, @asset}}} =
               Updater.download_update("0.2.10", opts)

      refute File.exists?(stored)

      # A file that matches SHA256SUMS, dropped where a download would be.
      File.write!(stored, "new binary")

      assert {:error, {:provenance_failed, {:subject_digest_mismatch, @asset}}} =
               Updater.install_update(%{}, "0.2.10", opts)

      assert File.read!(ctx.exe) == @old
      refute File.exists?(stored)
    end
  end
end

defmodule Raxol.CLI.Updater.StateTest do
  use ExUnit.Case, async: true

  alias Raxol.CLI.Updater.State

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol_state_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join([dir, "nested", "update_settings.json"])}
  end

  describe "new/1" do
    test "roots the default paths in the given home" do
      state = State.new("/home/someone")

      assert state.download_path == "/home/someone/.raxol/downloads"
      assert state.backup_path == "/home/someone/.raxol/backups"
      assert state.auto_check
      assert state.check_interval == 86_400
      assert state.last_check == nil
    end

    # Windows sets USERPROFILE, not HOME; the defaults must not need HOME.
    test "defaults to the user's home directory" do
      home = System.user_home!()

      assert State.new().download_path == Path.expand(Path.join([home, ".raxol", "downloads"]))
      assert State.new().backup_path == Path.expand(Path.join([home, ".raxol", "backups"]))
    end
  end

  describe "transitions" do
    test "a check is due once the interval has passed since the last one" do
      state = %{State.new("/h") | check_interval: 100}

      assert State.check_due?(state, 100)
      refute State.check_due?(State.checked(state, 50), 149)
      assert State.check_due?(State.checked(state, 50), 150)
    end

    test "no check is due with automatic checks off" do
      refute "/h" |> State.new() |> State.set_auto_check(false) |> State.check_due?(1_000_000)
    end
  end

  describe "decode/2" do
    test "keeps each valid field and defaults the rest" do
      defaults = State.new("/h")

      json =
        Jason.encode!(%{
          "auto_check" => false,
          "check_interval" => "often",
          "last_check" => -5,
          "download_path" => "/d",
          "backup_path" => ""
        })

      assert State.decode(json, defaults) == %{defaults | auto_check: false, download_path: "/d"}
    end

    test "malformed JSON or a non-object is the defaults" do
      defaults = State.new("/h")

      assert State.decode("{not json", defaults) == defaults
      assert State.decode("[1, 2]", defaults) == defaults
    end

    test "unknown keys are ignored and never become atoms" do
      key = "raxol_state_test_unknown_#{System.unique_integer([:positive])}"
      State.decode(Jason.encode!(%{key => true}), State.new("/h"))

      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    # The file the earlier GenServer wrote: its extra keys are dropped, the
    # ones still meaningful survive.
    test "reads settings written by earlier releases" do
      json =
        Jason.encode!(%{
          "auto_update" => true,
          "update_channel" => "stable",
          "auto_check" => false,
          "last_check" => 1_700_000_000,
          "retry_count" => 3
        })

      state = State.decode(json, State.new("/h"))

      refute state.auto_check
      assert state.last_check == 1_700_000_000
    end
  end

  describe "load/1 and save/2" do
    test "a missing file loads as the defaults", %{path: path} do
      assert State.load(path) == State.new()
    end

    test "what is saved loads back, through any missing directories", %{path: path} do
      state = State.new() |> State.set_auto_check(false) |> State.checked(42)

      assert :ok = State.save(state, path)
      assert State.load(path) == state
      assert File.ls!(Path.dirname(path)) == ["update_settings.json"]
    end

    test "a path that cannot be written is an error", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.mkdir_p!(path)

      assert {:error, _reason} = State.save(State.new(), path)
      assert File.ls!(Path.dirname(path)) == ["update_settings.json"]
    end

    test "path/1 takes :settings_path, else the user's ~/.raxol file", %{path: path} do
      assert State.path(settings_path: path) == path

      assert State.path([]) ==
               Path.join([System.user_home!(), ".raxol", "update_settings.json"])
    end
  end
end

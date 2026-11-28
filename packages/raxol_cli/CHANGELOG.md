# Changelog

## Unreleased

`raxol update` behaves as before. The `Raxol.CLI.Updater` library API changed:

- The updater no longer runs processes. `Raxol.CLI.Updater` and
  `Raxol.CLI.Updater.State.UpdaterServer` were GenServers that nothing
  started; both are gone, along with `start_link/1`.
- Settings are a `Raxol.CLI.Updater.State` struct (`auto_check`,
  `check_interval`, `last_check`, `download_path`, `backup_path`) read and
  written per call. `get_update_settings/1`, `set_update_settings/2` and
  `set_auto_check/2` take `:settings_path`; other keys in an existing
  `~/.raxol/update_settings.json` are ignored.
- Removed: `get_update_history/0`, `clear_update_history/0`,
  `get_update_progress/0`, `get_update_error/0`, `clear_update_error/0`,
  `get_update_log/0`, `clear_update_log/0`, `get_update_stats/0`,
  `clear_update_stats/0` and `handle_no_update/2`. Nothing recorded history,
  progress, errors, a log or stats, so they only ever returned defaults.
- `cancel_update/0` sent an exit signal the update ignored. In its place,
  `start_update/1` runs an update in a task the caller owns, with
  `await_update/2` and `cancel_update/1`.
- An update's scratch directory under the system temp dir is now created
  fresh with an unguessable name and mode `0700`. It was a predictable name
  created with `mkdir -p`, so on a shared `/tmp` another user could create
  it first and replace a verified download before it was installed.

`raxol new --help` and `raxol new -h` print the command's usage and exit 0,
wherever the flag appears (`raxol new my_app --help` creates nothing). A
flag in first position used to be refused as `invalid app name`.

## 0.3.0 - 2026-11-15

First release from `DROOdotFOO/raxol-agent`.

- Releases, the `raxol-cli-channel` manifest and `raxol update` now use
  `DROOdotFOO/raxol-agent`. The updater installs only binaries attested by
  that repository's `.github/workflows/release-raxol-cli.yml`. Releases up to
  0.2.10 stay on `DROOdotFOO/raxol`.
- A CLI at 0.2.10 or older cannot update itself to a release from
  `DROOdotFOO/raxol-agent`: its `raxol update` never reads this repository.
  Once `https://raxol.io/install` serves these releases, reinstall with
  `curl -fsSL https://raxol.io/install | bash`.

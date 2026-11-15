# Changelog

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

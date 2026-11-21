# Releasing the Hex packages

Three packages are published to Hex by hand, in this order, because Hex refuses a requirement on
a version it does not yet have:

1. `raxol_agent_client_protocol` (tag `raxol_agent_client_protocol-v<version>`);
2. `raxol_agent` (tag `raxol_agent-v<version>`), which requires the protocol package;
3. `raxol_payments` (tag `raxol_payments-v<version>`), which requires `raxol_agent`.

Publish only the packages whose `@version` changed, in that order. The runtime packages they
require (`raxol`, `raxol_core`, `raxol_mcp`, `raxol_journal`) come from the runtime repository and
must already be on Hex.

`HEX_BUILD=1` switches each `mix.exs` to its Hex form: sibling packages become Hex requirements,
and the unpublished `raxol_web3` is dropped. Every `mix` command below needs it.

## 1. Check out the release commit

Merge the release pull request, then publish from `main` as merged:

```sh
git fetch origin
git switch --detach origin/main
git status --short    # must print nothing
```

## 2. Toolchain

Use the Elixir and Erlang pinned in `mise.toml`, with the mise install's `bin` first in `PATH`
(otherwise a Homebrew `mix` runs Hex):

```sh
unset MIX_ENV RAXOL_PATH
which mix               # the mise path
mix hex.info            # Hex 2.7.0 or later
mix hex.user whoami     # the account that owns the packages
```

## 3. Publish each package

For each package, in order, with `<pkg>` and `<version>` filled in:

```sh
cd packages/<pkg>
cp mix.lock /tmp/<pkg>.mix.lock
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
git tag -a <pkg>-v<version> -m "<pkg> <version>"
test "$(git rev-parse HEAD)" = "$(git rev-parse '<pkg>-v<version>^{commit}')"
git push origin <pkg>-v<version>
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/<pkg>.mix.lock mix.lock
git status --short      # must print nothing
cd ../..
```

Check the dry run before tagging:

- `raxol_agent_client_protocol`: nothing under `priv/` may be listed. The schema oracle is
  Apache-2.0 and must never ship.
- `raxol_agent`: every requirement must already be on Hex, and `raxol_agent_client_protocol` must
  be listed and not optional.

A package's dry run cannot resolve until the package it requires shows on hex.pm. Push the tag
before publishing, because the docs link source files at the tag. If hex.pm holds the release for
approval, approve it at the URL the task prints, and `--wait` returns once the package is
published.

## If something fails

- `deps.get` cannot find a version that was just published: the registry has not caught up yet.
  Wait a minute and retry.
- The package was published but its docs were not: `HEX_BUILD=1 mix hex.publish docs`.
- A published version is wrong: `HEX_BUILD=1 mix hex.publish --revert <version>` works within 24
  hours of a package's first publish, and within one hour of a new version. Revert in the reverse
  order of publishing. If a dependent can no longer be reverted, publish a fixed patch version of
  the dependency instead of reverting it.

## After publishing

- `https://hexdocs.pm/<pkg>/<version>/` loads, and its source links land on the tag.
- In a scratch project, `{:raxol_agent, "~> <version>"}` resolves from Hex, and
  `mix run --no-start -e 'IO.inspect(Code.ensure_loaded?(Raxol.Agent.ClientProtocol.StdioAgent))'`
  prints `true`.

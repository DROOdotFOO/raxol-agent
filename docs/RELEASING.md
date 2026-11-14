# Releasing raxol_agent and raxol_payments

Both packages are published to Hex by hand, `raxol_agent` first: `raxol_payments`
requires `raxol_agent ~> 3.0`, and Hex refuses a requirement on a version it
does not have. The runtime packages they require (`raxol`, `raxol_core`,
`raxol_mcp`, `raxol_journal`, all `~> 2.8`) come from the runtime repository and
must already be on Hex.

`HEX_BUILD=1` gives each `mix.exs` its Hex form: sibling packages become Hex
requirements, and the unpublished `raxol_agent_client_protocol` and
`raxol_web3` drop out. Without it, `mix hex.publish` would ship path
dependencies.

## Toolchain

Use the pinned Elixir and Erlang from `mise.toml`. In a fresh or `pty` shell,
put the Elixir 1.20.2 install's `bin` first in `PATH`; otherwise a Homebrew
`mix` on the default `PATH` runs Hex:

```sh
export PATH="$HOME/.local/share/mise/installs/elixir/1.20.2-otp-29/bin:$HOME/.local/share/mise/installs/erlang/29.0.3/bin:$PATH"
which mix   # must print the mise path
```

## Tags

Each package's docs link source files at its own tag, so push the tag on the
release commit before publishing:

```sh
git tag -a raxol_agent-v3.0.0 -m "raxol_agent 3.0.0"
git tag -a raxol_payments-v0.3.0 -m "raxol_payments 0.3.0"
git push origin raxol_agent-v3.0.0 raxol_payments-v0.3.0
```

## Publish, in order

For `raxol_agent`, then `raxol_payments`, from `packages/<pkg>`:

```sh
cd packages/raxol_agent
cp mix.lock /tmp/mix.lock.bak
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/mix.lock.bak mix.lock    # the Hex form rewrites the lock
git status --short               # must be clean
```

Read the dry run's dependency list before publishing: every requirement must
already be on Hex, optional ones included. `--wait` returns once Hex has
accepted the release; new versions of existing packages are not staged, so it
changes nothing else.

Publish `raxol_payments` only after `raxol_agent` 3.0.0 shows at
`https://hex.pm/packages/raxol_agent`; its `HEX_BUILD=1 mix deps.get` cannot
resolve before then.

## After publishing

- Check `https://hexdocs.pm/raxol_agent/3.0.0/` and
  `https://hexdocs.pm/raxol_payments/0.3.0/`, and that a source link on each
  lands on its tag under `packages/<pkg>/`.
- In a scratch project, `{:raxol_payments, "~> 0.3"}` with `mix deps.get` and
  `mix compile` resolves both packages from Hex.

# Releasing raxol_agent and raxol_payments

Both packages are published to Hex by hand, `raxol_agent` first: `raxol_payments`
requires `raxol_agent ~> 3.0`, and Hex refuses a requirement on a version it
does not have. The runtime packages they require (`raxol`, `raxol_core`,
`raxol_mcp`, `raxol_journal`, all `~> 2.8`) come from the runtime repository and
must already be on Hex.

`HEX_BUILD=1` gives each `mix.exs` its Hex form: sibling packages become Hex
requirements, and the unpublished `raxol_agent_client_protocol` and
`raxol_web3` drop out. Every `mix` command below that builds or publishes needs
it.

## 1. Check out the release commit

Merge the release pull request first. Then publish from `main` exactly as
merged:

```sh
git fetch origin
git switch --detach origin/main
git status --short    # must print nothing
```

## 2. Toolchain

Use the pinned Elixir and Erlang from `mise.toml`, either with `mise exec --`
in front of every `mix` command or with this environment. Put the install's
`bin` first in `PATH`; otherwise a Homebrew `mix` runs Hex:

```sh
export PATH="$HOME/.local/share/mise/installs/elixir/1.20.2-otp-29/bin:$HOME/.local/share/mise/installs/erlang/29.0.3/bin:$PATH"
export MIX_HOME="$HOME/.local/share/mise/installs/elixir/1.20.2-otp-29/.mix"
export MIX_ARCHIVES="$MIX_HOME/archives"
unset MIX_ENV RAXOL_PATH
which mix               # the mise path
mix hex.info            # Hex 2.7.0 or later
mix hex.user whoami     # the account that owns both packages
```

## 3. Dry run the agent

```sh
cd packages/raxol_agent
cp mix.lock /tmp/raxol_agent.mix.lock
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
```

Read the dependency list it prints: every requirement must already be on Hex,
optional ones included. The `raxol_payments` dry run cannot resolve until
`raxol_agent` 3.0.0 is published, so it waits for step 5.

## 4. Tag and publish the agent

```sh
git tag -a raxol_agent-v3.0.0 -m "raxol_agent 3.0.0"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'raxol_agent-v3.0.0^{commit}')"
git push origin raxol_agent-v3.0.0
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/raxol_agent.mix.lock mix.lock
git status --short      # must print nothing
cd ../..
```

The docs link source files at the tag, so it is pushed first. hex.pm may hold a
release for approval: the task prints the approval URL; approve it there, and
`--wait` returns once it is published.

## 5. Dry run, tag and publish payments

Once `raxol_agent` 3.0.0 shows at `https://hex.pm/packages/raxol_agent`:

```sh
cd packages/raxol_payments
cp mix.lock /tmp/raxol_payments.mix.lock
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
git tag -a raxol_payments-v0.3.0 -m "raxol_payments 0.3.0"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'raxol_payments-v0.3.0^{commit}')"
git push origin raxol_payments-v0.3.0
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/raxol_payments.mix.lock mix.lock
git status --short      # must print nothing
```

## If something fails

- `HEX_BUILD=1 mix deps.get` cannot find `raxol_agent` 3.0.0 right after it was
  published: the registry has not caught up. Wait a minute and run it again.
- The package published but its docs did not: `HEX_BUILD=1 mix hex.publish docs`.
- A published version is wrong: `HEX_BUILD=1 mix hex.publish --revert <version>`
  works within one hour of publishing a new version of an existing package
  (`mix help hex.publish`). Reverting `raxol_agent` 3.0.0 after `raxol_payments`
  0.3.0 is out breaks `raxol_payments`; revert payments first.

## After publishing

- `https://hexdocs.pm/raxol_agent/3.0.0/` and
  `https://hexdocs.pm/raxol_payments/0.3.0/` load, and a source link on each
  lands on its tag under `packages/<pkg>/`.
- In a scratch project, `{:raxol_payments, "~> 0.3"}` with `mix deps.get` and
  `mix compile` resolves both packages from Hex.

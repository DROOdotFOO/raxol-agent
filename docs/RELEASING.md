# Releasing the Hex packages

Three packages of this repository are published to Hex by hand, always in this
order, because Hex refuses a requirement on a version it does not have:

1. `raxol_agent_client_protocol` (tag `raxol_agent_client_protocol-v<version>`),
   which requires no other package of this repository;
2. `raxol_agent` (tag `raxol_agent-v<version>`), which requires
   `raxol_agent_client_protocol ~> 0.1.0`;
3. `raxol_payments` (tag `raxol_payments-v<version>`), which requires
   `raxol_agent ~> 3.0`.

Publish only the packages whose `@version` the release changes, still in that
order. This release is `raxol_agent_client_protocol` 0.1.0 (its first publish)
and `raxol_agent` 3.1.0; `raxol_payments` stays at 0.3.0, which is already on
Hex, so step 5 is skipped. The runtime packages they require (`raxol`,
`raxol_core`, `raxol_mcp`, `raxol_journal`, all `~> 2.8`) come from the runtime
repository and must already be on Hex.

`HEX_BUILD=1` gives each `mix.exs` its Hex form: sibling packages become Hex
requirements, and the unpublished `raxol_web3` drops out. Every `mix` command
below that builds or publishes needs it.

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
mix hex.user whoami     # the account that owns raxol_agent and raxol_payments; it becomes the owner of raxol_agent_client_protocol on first publish
```

## 3. Publish the protocol package

```sh
cd packages/raxol_agent_client_protocol
cp mix.lock /tmp/raxol_agent_client_protocol.mix.lock
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
```

Read the file list it prints: nothing under `priv/` may appear (the schema
oracle is a dev/test file under the Apache-2.0 licence and never ships). Then:

```sh
git tag -a raxol_agent_client_protocol-v0.1.0 -m "raxol_agent_client_protocol 0.1.0"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'raxol_agent_client_protocol-v0.1.0^{commit}')"
git push origin raxol_agent_client_protocol-v0.1.0
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/raxol_agent_client_protocol.mix.lock mix.lock
git status --short      # must print nothing
cd ../..
```

The docs link source files at the tag, so it is pushed first. hex.pm may hold a
release for approval: the task prints the approval URL; approve it there, and
`--wait` returns once it is published.

## 4. Dry run, tag and publish the agent

The agent's dry run cannot resolve until the protocol package is published.
Once `raxol_agent_client_protocol` 0.1.0 shows at
`https://hex.pm/packages/raxol_agent_client_protocol`:

```sh
cd packages/raxol_agent
cp mix.lock /tmp/raxol_agent.mix.lock
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
```

Read the dependency list it prints: every requirement must already be on Hex,
optional ones included, and `raxol_agent_client_protocol ~> 0.1.0` must be
there and not optional. Then:

```sh
git tag -a raxol_agent-v3.1.0 -m "raxol_agent 3.1.0"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'raxol_agent-v3.1.0^{commit}')"
git push origin raxol_agent-v3.1.0
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/raxol_agent.mix.lock mix.lock
git status --short      # must print nothing
cd ../..
```

## 5. Dry run, tag and publish payments

Only when the release changes `raxol_payments`' `@version`. Once the
`raxol_agent` version it requires shows at `https://hex.pm/packages/raxol_agent`,
with `<version>` the new `@version`:

```sh
cd packages/raxol_payments
cp mix.lock /tmp/raxol_payments.mix.lock
HEX_BUILD=1 mix deps.get
HEX_BUILD=1 mix hex.publish --dry-run
git tag -a raxol_payments-v<version> -m "raxol_payments <version>"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'raxol_payments-v<version>^{commit}')"
git push origin raxol_payments-v<version>
HEX_BUILD=1 mix hex.publish --wait
cp /tmp/raxol_payments.mix.lock mix.lock
git status --short      # must print nothing
```

## If something fails

- `HEX_BUILD=1 mix deps.get` cannot find a version right after it was
  published: the registry has not caught up. Wait a minute and run it again.
- The package published but its docs did not: `HEX_BUILD=1 mix hex.publish docs`.
- A published version is wrong: `HEX_BUILD=1 mix hex.publish --revert <version>`
  works within 24 hours of a new package's first publish
  (`raxol_agent_client_protocol` 0.1.0) and within one hour of a new version of
  an existing package (`raxol_agent` 3.1.0) (`mix help hex.publish`, Hex 2.7.0).
  Revert in the reverse order of publishing: reverting
  `raxol_agent_client_protocol` 0.1.0 after `raxol_agent` 3.1.0 is out breaks
  `raxol_agent`, so revert the agent first. Once the agent's hour has passed it
  can no longer be reverted, so do not revert `raxol_agent_client_protocol`
  0.1.0 either (that would leave `raxol_agent` 3.1.0 unresolvable): publish a
  fixed 0.1.1 instead.

## After publishing

- `https://hexdocs.pm/raxol_agent_client_protocol/0.1.0/` and
  `https://hexdocs.pm/raxol_agent/3.1.0/` load, and a source link on each
  lands on its tag under `packages/<pkg>/`.
- In a scratch project, `{:raxol_agent, "~> 3.1"}` with `mix deps.get` and
  `mix compile` resolves `raxol_agent_client_protocol` 0.1.0 from Hex, and
  `mix run --no-start -e 'IO.inspect(Code.ensure_loaded?(Raxol.Agent.ClientProtocol.StdioAgent))'`
  prints `true`.

# Tagging raxol_broker

`raxol_broker` is released as a tagged commit, not on Hex: the tag pins the
code and the tool capture (`packages/raxol_broker/priv/robinhood/tools_list.json`)
it was tested against. The executor refuses any order or review tool whose
schema differs from that capture, so a tag records exactly what may trade.

## 1. Before tagging

- The release pull request is merged; check out `origin/main` as in
  "Check out the release commit" above.
- The capture is current. With the operator's Robinhood sign-in, run
  `mix raxol.broker.connect --account <account>` from `packages/raxol_broker`;
  it must print `no drift from the capture`. Otherwise recapture with
  `mix raxol.broker.capture_tools`, regenerate with
  `mix raxol.broker.gen.tools`, review the diff and merge it first.
- In `packages/raxol_broker/CHANGELOG.md`, replace `Unreleased` in the
  version heading with the date, in the release pull request.

## 2. The gate

From `packages/raxol_broker`, with the toolchain above and `MIX_ENV=test`:

```sh
mix deps.get --check-locked
mix compile --warnings-as-errors
mix test --exclude skip_on_ci
mix format --check-formatted
```

## 3. Tag

With `<version>` the `@version` in `packages/raxol_broker/mix.exs` and
`<captured>` the capture's `provenance.captured`:

```sh
git tag -a raxol_broker-v<version> -m "raxol_broker <version>, tool capture <captured>"
test "$(git rev-parse HEAD)" = "$(git rev-parse 'raxol_broker-v<version>^{commit}')"
git push origin raxol_broker-v<version>
```

The docs' source links (`source_ref` in `mix.exs`) point at this tag. No
`mix hex.publish` runs for `raxol_broker`.

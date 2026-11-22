# Changelog

All notable changes to `raxol_agent_client_protocol` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - Unreleased

### Changed

- **Breaking: `Transport.Stdio.start_spawn/3` no longer hands a spawned
  agent the node's credentials.** It applies `Raxol.Core.ChildEnv`, the scrub
  raxol's directive shells and MCP stdio servers use. Unset unless named in
  `:env` or the new `:pass`:
  - any name with a credential word as a `_`-separated segment (`KEY`,
    `KEYS`, `APIKEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `PASSPHRASE`,
    `MNEMONIC`, `CREDENTIALS`, ...), case-insensitive, so `API_KEYS`
    and a bare `TOKEN` go too;
  - database and broker URLs (`DATABASE_URL`, `REDIS_URL`, ...),
    `PGPASSWORD`, and `RPC` anywhere in a name but `GRPC`;
  - raxol_core's named set (`SECRET_KEY_BASE`, `RELEASE_COOKIE`,
    `SSH_AUTH_SOCK`, raxol's own keys) and the operator's `extra_secrets:`;
  - on top of Core, names with a `_PASS`, `_SEED_PHRASE` or `_DSN` suffix,
    `SEED_PHRASE` and `OP_SESSION_*`, which Core 2.9's pattern misses
    (`Transport.Stdio.credential_gaps/0`; raxol_agent reuses it).

  Also:
  - **Core's node-wide `pass:` list is not honoured.** A name the operator
    lets through to directive shells or MCP servers with
    `config :raxol_core, Raxol.Core.ChildEnv, pass:` is unset in a spawned
    ACP agent, which is third-party code. A spawn hands an agent a name with
    its own `:pass` option (exact names) or `:env`.
  - Precedence, highest first: `:env` (set as given), `:unset_env` (unset),
    `:pass` (inherited), then the scrub.
  - Raised from `start_spawn/3` in the caller, before anything is spawned:
    `ArgumentError` for a malformed `Raxol.Core.ChildEnv` config or a
    malformed `:env` (a `nil` value, say), `:scrub_env` (anything but
    `true`/`false`), `:unset_env` or `:pass`; `RuntimeError` when
    `Raxol.Core.ChildEnv` is not loadable (see below).
  - New: `Transport.Stdio.secret?/2` says whether a name is scrubbed.

  An agent that reads its own provider key from the environment needs it
  passed in `:env` or `:pass`, or `scrub_env: false` for the old behaviour.
  Breaking for such agents, hence 0.2.0.
- **Requires `raxol_core ~> 2.9` as a `runtime: false` dependency.** Only
  `Raxol.Core.ChildEnv`'s code is used, so raxol_core is not started, nor the
  `:mnesia` its `.app` lists, and `:telemetry` stays optional. A Mix release
  leaves a `runtime: false` dependency out: a release that does not already
  start raxol_core must add `applications: [raxol_core: :load]`, or
  `start_spawn/3` raises rather than spawn an agent unscrubbed (README,
  "Releases").
- Also ships the connection, delivery, journal writer and attach-policy
  robustness and security fixes merged in #27.
- **A cancelled request is now answered.** After `$/cancel_request` the
  Connection sends exactly one response for the id, as the ACP schema
  requires: `-32800` for an undelegated request, otherwise the adopter's reply
  (`Session` answers `stopReason: cancelled`), or `-32800` if the adopter exits
  or does not reply within `:cancel_reply_timeout_ms`. Previously it sent
  nothing. Consequences: `Connection.delegate_reply/3` returns
  `{:error, :unknown_ref}` (not `{:error, :cancelled}`) once the peer has
  cancelled an undelegated request, and the peer's answer to a request this
  side cancelled or timed out no longer emits `[:raxol, :acp, :late_response]`.
- After the peer closes its write side, a `Connection` stops once every
  in-flight request is answered (bounded by `:close_drain_ms`, default five
  minutes) instead of after a fixed five seconds. While draining it refuses new
  outbound requests and fails pending ones with `:connection_closed` (they can
  no longer be answered); notifications still go out. A peer that is gone
  entirely (process exit, Paired peer closed) is not drained.
- MCP server descriptors are type-checked: `name`, `url`, `command`, `args`
  (a list of strings) and env/header names and values must be strings, and an
  unknown `type` is refused (`"stdio"` and `"args": null` are accepted); such a
  request fails with `-32602`.

### Added

- `Connection` options:
  - `:max_notification_tasks` (default 500): at most that many notification
    handlers run at once, in their own task pool, so they cannot use up the
    capacity requests need.
  - `:max_queued_notifications` (default 10_000) and
    `:max_queued_notification_bytes` (default 64 MiB, measured as the external
    term size of the params): notifications arriving at the handler cap wait
    in order for a free handler within both bounds. Only those arriving with
    the backlog full, and any still waiting when the connection closes, are
    dropped with `[:raxol, :acp, :notification_shed]`; each one that waits
    emits `[:raxol, :acp, :notification_queued]` with the backlog depth.
  - `:close_drain_ms` (default five minutes; see above).
  - `:cancel_reply_timeout_ms` (default 60_000, longer than `Session`'s 30s
    cancel backstop).

  Like `:max_inbound`, invalid values stop the Connection at start.
- The application starts a sixth child, `Client.Subscriptions`.
- `Error.request_cancelled/0` (`-32800`).

### Fixed

- The `Client.subscribe/3` table is owned by a long-lived process (an
  application child, started on demand otherwise), so it no longer disappears
  with the short-lived task that first created it; entries for exited
  subscribers and connections are removed.

## [0.1.0] - 2026-11-14

First release. An Elixir/OTP implementation of ACP (Agent Client Protocol) v1,
following the pinned `schema-v1.19.0` method set, in both roles: the agent and
client behaviours (`Raxol.AgentClientProtocol.Agent`, `Raxol.AgentClientProtocol.Client`)
over one supervised `Connection` per peer, the `Schema.*` wire types with total
decoding, the JSON-RPC 2.0 envelope, stdio and in-process transports, per-session
processes, and the `_raxol/*` vendor extension for resumable sessions (an
in-memory journal, reattach with replay, and `RXC1` capability tokens). Its
application starts two `Registry`s, two `DynamicSupervisor`s and one
`Task.Supervisor` (no files, ports or listeners); a client can confine
`fs/*` to a directory with `fs_sandbox:`. Requires `jason ~> 1.4`.

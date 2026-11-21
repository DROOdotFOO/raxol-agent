# Changelog

All notable changes to `raxol_agent_client_protocol` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - Unreleased

### Changed

- **Breaking: `Transport.Stdio.start_spawn/3` no longer hands a spawned
  agent the node's credentials.** Variables whose name ends in
  `_KEY`, `_KEY_ID`, `_APIKEY`, `_TOKEN`, `_PRIVKEY`, `_SECRET`, `_PASSWORD`,
  `_PASS`, `_PASSPHRASE`, `_MNEMONIC`, `_SEED_PHRASE`, `_CREDENTIALS`, `_DSN` or
  `_RPC` (case-insensitive), every `RPC_` name, `MNEMONIC`, `SEED_PHRASE`,
  `SSH_AUTH_SOCK` and `OP_SESSION_*` are unset unless named in `:env`;
  `:unset_env` adds names of the caller's own. An agent that reads its own
  provider key from the environment needs it passed in `:env`, or
  `scrub_env: false` for the old behaviour. Breaking for such agents, hence
  0.2.0.
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

- `Connection` options `:max_notification_tasks` (default 500: notification
  handlers run in their own task pool of that size, so they cannot use up the
  capacity requests need), `:close_drain_ms` and `:cancel_reply_timeout_ms`
  (default 60_000, longer than `Session`'s 30s cancel backstop). Like
  `:max_inbound`, invalid values stop the Connection at start.
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

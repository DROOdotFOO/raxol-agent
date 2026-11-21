# Changelog

All notable changes to `raxol_agent_client_protocol` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`Transport.Stdio.start_spawn/3` no longer hands a spawned agent the
  node's credentials.** Variables whose name ends in `_KEY`, `_KEY_ID`,
  `_TOKEN`, `_PRIVKEY`, `_SECRET`, `_PASSWORD`, `_PASSPHRASE`, `_MNEMONIC` or
  `_CREDENTIALS` (case-insensitive), and every `RPC_` name, are unset unless
  named in `:env`. An agent that reads its own provider key from the
  environment needs it passed in `:env`, or `scrub_env: false` for the old
  behaviour. Breaking for such agents; release as 0.2.0.

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

# Changelog

All notable changes to `raxol_agent_client_protocol` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-14

First release. An Elixir/OTP implementation of ACP (Agent Client Protocol) v1,
following the pinned `schema-v1.19.0` method set, in both roles: the agent and
client behaviours (`Raxol.AgentClientProtocol.Agent`, `Raxol.AgentClientProtocol.Client`)
over one supervised `Connection` per peer, the `Schema.*` wire types with total
decoding, the JSON-RPC 2.0 envelope, stdio and in-process transports, per-session
processes, and the `_raxol/*` vendor extension for resumable sessions (an
in-memory journal, reattach with replay, and `RXC1` capability tokens). Requires
`jason ~> 1.4`.

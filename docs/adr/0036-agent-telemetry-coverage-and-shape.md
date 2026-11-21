# ADR-0036: Agent telemetry shape

## Status

Accepted, 2026-09-05. Narrowed 2026-11-13 by [ADR-0042](0042-lean-on-omp.md): the money-path
events (`[:raxol, :agent, :cost | :budget, ...]`), the `:policy` family and the ACP turn-runner
events are removed along with the code that emitted them. The planned latency, log-promotion and
metadata tiers were not built.

## Context

The agent packages detected impossible states and only logged them, so no test failed when a
defect fired. Event names were built at runtime and could not be scanned. Metadata leaked tool
arguments and other unbounded values.

## Decision

`Raxol.Agent.Telemetry` registers every event `raxol_agent` emits and classifies each as
exactly one of:

- `:invariant`: fires only if raxol itself is wrong. A test module that uses
  `Raxol.Agent.Test.InvariantSentinel` fails when one fires, unless the test tags it with
  `expect_invariant:`.
- `:peer`: the remote side misbehaved. Expected in negative tests.
- `:operational`: normal life, such as a sandbox denial or a refused filesystem write.

If a peer, the network, the filesystem, the clock or a user can cause an event, it is not an
invariant. A false invariant makes the suite flaky, and a flaky guard gets deleted.

Every event follows these rules:

1. One event per condition. A name never covers both a happy path and a failure.
2. Static names only. The varying part goes in metadata.
3. Measurements are numbers. Metadata is context.
4. Correlation: `session_id`, `turn_id` and `agent_id` where they exist. These are attributes,
   never metric labels.
5. Cardinality: bounded atoms may be labels. Unbounded ids are attributes only. Prompts, tool
   arguments, file contents, addresses and credentials appear nowhere.
6. Any value the emitter did not build itself goes through `Telemetry.bound/1`, which keeps the
   shape of a term and redacts long binaries, structs, pids and funs.
7. An argument is identified by `Telemetry.digest/1`: HMAC-SHA256 under a 32-byte key generated
   once per VM run and never persisted, so an audit log cannot be used to confirm a guessed
   argument offline. A digest joins events within one run, never across runs or nodes. It is
   computed once per operation. Measured on Apple M1 with pre-built terms, OTP 28, two runs:
   3 us at 1 KB, 90 us at 100 KB, 1.1 ms at 1 MB, of which the key costs about 40% over an
   unkeyed hash.

## Consequences

- `test/raxol/agent/telemetry_registry_test.exs` parses `lib/` and fails on an unregistered event.
- No event is `:invariant` at present, so the sentinel enforces nothing yet.
- Do not add `:telemetry` to `raxol_agent/mix.exs`, because it already loads through `raxol_core`.

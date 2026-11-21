# ADR-0031: Raxol as a Virtuals ACP Console runtime

## Status

Proposed, 2026-07-29. The `raxol_console` loader is implemented and tested. Native ACP seller
registration and the Console's runtime registration contract are blocked on Virtuals.
Amended 2026-11-13 by [ADR-0042](0042-lean-on-omp.md): the console runtime has no native
memory.

## Context

The Virtuals Agent Commerce Protocol (ACP) Console provisions a managed agent runtime from a package (`soul.md`,
`AGENTS.md`, `tasks.json`, `skills/<name>/SKILL.md`, `manifest.json`). Hermes (Nous Research) and
OpenClaw, two open-source agent runtimes, are the ones on offer. `raxol_earn` already generates these packages. Raxol can run the
same packages as a third runtime, with ACP, settlement and spend gating built in rather than
shelled out to a CLI.

## Decision

- A new top-level package, `raxol_console`, loads a Console package and boots a Raxol runtime.
  It depends on `raxol_agent`, `raxol_gateway`, `raxol_earn` and `raxol_payments`. It ships as a
  Burrito binary in an npm wrapper, so an `acp-cli` that installs Node packages can install it.
- Loading is pure: `Raxol.Earn.Console.Package.load/1` reads the package, and
  `Raxol.Console.RuntimeConfig` merges it with the deployment environment. `soul.md` is the
  system prompt, and `AGENTS.md`, when present, is appended under an operating-rules heading.
- `Raxol.Console.Boot` is effectful and idempotent. It starts `Raxol.Console.Supervisor`
  (scheduler, reconciler, skills store when the package ships skills, and bundled MCP servers
  under their own `DynamicSupervisor`). It starts the gateway last, so the handler sees the
  resolved tools.
- Scheduled tasks reuse the scheduler (ADR-0025). `Raxol.Console.Scheduler.Wiring` gives it the
  persona and a `:deliver` closure over `Raxol.Gateway.Delivery.deliver/3`. The reconciler
  makes the job set match `tasks.json`, keyed by task name, and records a failed operation
  instead of raising.
- The `acp-cli` provisions the credentials (wallets, email, card, ACP identity), and
  `raxol_earn` uses them natively.
- `raxol_earn` accepts `"raxol"` as a runtime. `Console.Bench` is a behaviour injected by config,
  and `Raxol.Console.Bench.Adapter` implements it, which avoids a compile cycle.

## Consequences

- Raxol runs the package format it already generates.
- Whether Raxol appears in the picker depends on a partner agreement, not on this design.
- Open questions: whether the `acp-cli` accepts a non-Node runtime and what manifest it needs; how
  provisioned credentials reach the process; and which on-chain identity standard ACP
  registration uses. Registration scaffolding exists behind a fail-closed gate.
- OS-level process sandboxing comes from the Console host. Raxol adds in-BEAM guards
  (tool policy and spend gate).

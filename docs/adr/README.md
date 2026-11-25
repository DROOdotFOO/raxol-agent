# Architecture decisions

Each ADR records one decision that is in force, with its status, context and consequences.

| ADR | Decision |
| --- | --- |
| [0020](0020-agent-sandbox-thread-policies.md) | Agent sandbox and thread log |
| [0021](0021-self-improving-agents-skills-curation.md) | Agent skill runtime |
| [0025](0025-cronjob-scheduled-tasks.md) | Scheduled agent jobs |
| [0030](0030-acp-session-update-delivery-ordering.md) | ACP `session/update` delivery ordering |
| [0031](0031-console-runtime-integration.md) | Raxol as a Virtuals ACP Console runtime |
| [0033](0033-web3-data-surface.md) | Indexer-agnostic web3 read layer (`raxol_web3`) |
| [0034](0034-foreign-coding-agent-seams.md) | Foreign coding-agent seams |
| [0036](0036-agent-telemetry-coverage-and-shape.md) | Agent telemetry shape |
| [0038](0038-guarded-outbound-client-evm-rest-backend.md) | Guarded outbound client and the EVM REST backend |
| [0039](0039-required-callback-set-partial-sources.md) | Required callback set and partial sources |
| [0040](0040-fx-market-data-and-rate-sources.md) | FX market data and rate sources |
| [0041](0041-agent-client-protocol-package.md) | `raxol_agent_client_protocol`: origin, layering and license |
| [0042](0042-lean-on-omp.md) | Lean on OMP |

## Removed

These were deleted when their code was removed or replaced. Their text is in git history.

- 0016, 0017: the v1 earn job workflow, replaced by the v2 `JobSession` model in `raxol_earn`.
- 0018: the operator flow contract for Symphony, which moved to its own repository.
- 0022, 0024, 0026, 0027, 0028, 0035: the coding-agent harness (memory, execution backends,
  code execution, subagents and related work), superseded by [ADR-0042](0042-lean-on-omp.md).
- 0032: a sandboxed-spawn design that was never built.

Also removed: `docs/proposals/web3-upstream-survey.md`, a dated log of upstream probes (see
ADR-0033).

Numbers missing from both lists are not in this repository's history. That includes ADR-0037,
which some code comments in `raxol_web3` and `raxol_agent` still cite.

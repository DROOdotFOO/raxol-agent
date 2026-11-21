# Skill Authoring

A skill is a reusable `SKILL.md` that teaches an agent a procedure. Raxol uses the
[agentskills.io](https://agentskills.io) format, so skills under `~/.agents/skills` are read
as-is.

## Format

```markdown
---
name: git-bisect-a-regression
description: Find the commit that introduced a bug using git bisect.
version: "1"
category: git
---

# Git bisect a regression

Use this when a test passed at some older commit and fails now.

1. `git bisect start`
2. `git bisect bad` at the current commit.
3. `git bisect good <known-good-sha>`.
4. For each commit, run the failing test and mark it `good` or `bad`.
5. When git prints the first bad commit, run `git bisect reset`.
```

| Field | Required | Notes |
| --- | :---: | --- |
| `name` | yes | Kebab-case, unique within a store. |
| `description` | no | One line, shown by `skills_list`. |
| `version` | no | A string. |
| `category` | no | Directory on disk: `<root>/<category>/<name>/`. |
| `created_by` | no | `agent` or `user`. `skill_manage` sets `user`. |

Other frontmatter keys are kept as metadata. Nothing from a `SKILL.md` becomes an atom. Write the
body for an LLM that will act on it: when to use the skill, then the steps, then the caveats. Keep
each skill to one task.

## Store

`Raxol.Agent.Skills.Store` indexes two places:

- the managed root (writable, default `~/.raxol/skills`), where new skills are written;
- external dirs (read-only, default `~/.agents/skills`), scanned for `**/SKILL.md`. A managed
  skill wins over an external one with the same name.

Skills are re-read from disk on every boot. Usage counts, lifecycle state (`active`, `stale`,
`archived`) and pins persist to DETS. Nothing ages skills automatically. A host can do it with
`set_state/3`, `pin/2`, `archive/2` and `telemetry/1`.

## Enabling skills on an agent

```elixir
config :raxol_agent,
  skills_provider: Raxol.Agent.Skills.Store,
  skills_root: "~/.raxol/skills"
```

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def skills_provider, do: Raxol.Agent.Skills.Store
end
```

An agent that does not define `available_actions/0` gets the three skill tools from
`skills_provider/0` alone. The tools read the store from the call context:

```elixir
Raxol.Agent.Stream.react("which skills do you have?",
  backend: backend,
  actions: Raxol.Agent.Actions.Skills.actions(),
  context: %{skills: Raxol.Agent.Skills.provider_context(MyAgent.skills_provider())}
)
```

| Tool | Input | Returns |
| --- | --- | --- |
| `skills_list` | none | metadata only |
| `skill_view` | `name`, optional `path` | the body, or one supporting file |
| `skill_manage` | `action` (`create`/`patch`/`edit`/`delete`), `name`, fields | `ok`, `name` |

`skill_view` rejects absolute paths and `..`, so a skill cannot read outside its directory. A tool
call made while following a skill is gated like any other: a `sensitive` action is denied
without a `:tool_authorizer` that allows it.

# Agent Framework

An agent is a TEA module (`init/update/view`) whose input comes from models, tools and other
agents instead of a keyboard. It runs as a supervised, crash-isolated process. For wallets and
spending limits, see [Agentic Commerce](AGENTIC_COMMERCE.md).

## An agent

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def init(_ctx), do: %{findings: []}

  def update({:agent_message, _from, {:analyze, file}}, model) do
    {model, [shell("wc -l #{file}")]}
  end

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    {%{model | findings: [out | model.findings]}, []}
  end
end

{:ok, _} = Raxol.Agent.Session.start_link(app_module: MyAgent, id: :my_agent)
Raxol.Agent.Session.send_message(:my_agent, {:analyze, "mix.exs"})
{:ok, model} = Raxol.Agent.Session.get_model(:my_agent)
```

`use Raxol.Agent` defines overridable `init/1`, `update/2`, `view/1` and `subscribe/1`. `view/1`
defaults to `nil`, which gives a headless agent. `Raxol.Agent.Session` wraps the runtime
lifecycle with `environment: :agent`, which skips the terminal driver. Sessions register in
`Raxol.Agent.Registry` by `:id`.

Commands returned from `update/2`:

| Helper | Result in `update/2` |
| --- | --- |
| `async(fn sender -> ... end)` | `{:command_result, {:async_result, value}}` |
| `shell("ls -la")` | `{:command_result, {:shell_result, %{output: ..., exit_status: ...}}}` |
| `send_agent(:target, msg)` | delivered as `{:agent_message, from, msg}` |

## Communication

```elixir
alias Raxol.Agent.Comm

# Fire and forget. `from:` is asserted by the caller, not verified; without it the target sees nil.
:ok = Comm.send(:target_agent, {:task, data}, from: :my_agent)

# Synchronous. The target answers from update/2 with Comm.reply(caller, ref, answer).
{:ok, reply} = Comm.call(:target_agent, {:query, params}, 5_000)

# Every agent whose session has this team_id.
:ok = Comm.broadcast_team(:my_team, {:status_update, status})
```

### Agent turn contract

A prompt is one turn: `Comm.call(agent, {:acp_prompt, text, approver}, timeout)` returns
`{:ok, {:ok, text, usage}}`. `approver` is an arity-3 `:tool_authorizer` (see
`Raxol.Agent.ToolPolicy`) that every tool call of the turn must pass.

- The timeout is required (`:infinity` for none), because a timeout cancels the turn.
- `update/2` sees the prompt with the session's pid and the session's own ref, never the caller's.
  It answers inline with `Comm.reply/3`, or with `Comm.run_turn/3` for work that blocks.
- Consult `approver`, and run the actions it gates, inside the `Comm.run_turn/3` process. Never do
  this inline: an inline ask blocks the whole agent, and a cancel cannot stop inline work.
- `{:acp_cancel, ref}` stops the turn's process (with exit reason `:shutdown`, then a kill after
  `config :raxol_agent, :turn_cancel_grace_ms`, default 500) and answers `{:error, :cancelled}`.
  A turn is also cancelled when its caller goes down or its call times out.
- Whenever a turn ends without a reply, `update/2` receives `{:acp_cancel, ref}` with its own
  ref, so the agent can drop its per-turn state in one place.
- A turn process changes agent state by sending `{:command_result, msg}` to the agent. A cancel
  does not roll back a change already sent.
- Other answers: `{:error, :invalid_prompt}`, `:duplicate_ref`, `:no_dispatcher`,
  `:turn_failed`, `:agent_down`, `:timeout_required`.
- The session journals each turn: `turn_started`, then `turn_completed`, `turn_canceled` or
  `error`.

`Raxol.Agent.Reference.Counter` is the reference agent for this contract.

## Teams

```elixir
{:ok, _} = Raxol.Agent.Team.start_link(
  team_id: :review_team,
  coordinator: {ReviewCoordinator, [id: :coordinator]},
  workers: [{FileAnalyzer, [id: :analyzer_1]}, {FileAnalyzer, [id: :analyzer_2]}],
  strategy: :rest_for_one
)
```

The coordinator starts first. With `:rest_for_one`, a coordinator crash restarts the workers.

## Tools

A tool is a `use Raxol.Agent.Action` module. An agent declares its tools with
`available_actions/0`.

```elixir
defmodule Tools.CountLines do
  use Raxol.Agent.Action,
    name: "count_lines",
    description: "Count the lines in a file.",
    schema: [input: [path: [type: :string, required: true, description: "File path"]]]

  def run(%{path: path}, _context) do
    {:ok, %{lines: path |> File.read!() |> String.split("\n") |> length()}}
  end
end
```

A tool marked `sensitive: true` is denied unless the call's context carries a `:tool_authorizer`
that allows it. The [Tool Catalog](../reference/TOOL_CATALOG.md) lists the built-in tools.

## Turn loop

`Raxol.Agent.Stream.react/2` runs one turn: the model sees the tools in `:actions`, each tool call
runs, and the loop continues until the model answers in text or `:max_iterations` is reached.

```elixir
{:ok, backend, backend_opts} =
  Raxol.Agent.Backend.Selector.select(
    Raxol.Agent.ExecutorConfig.new(
      harness: :anthropic,
      model: "claude-sonnet-5",
      auth: %{api_key: System.fetch_env!("ANTHROPIC_API_KEY")}
    )
  )

{:ok, result} =
  "how many lines are in mix.exs?"
  |> Raxol.Agent.Stream.react(backend: backend, backend_opts: backend_opts, actions: [Tools.CountLines])
  |> Raxol.Agent.Stream.collect()
```

`react/2` returns a lazy stream of `{:text_delta, _}`, `{:tool_use, _}`, `{:tool_result, _}` and
`{:done, info}`. `collect/1` drains it to `{:ok, info}`. `:context` is passed to every tool call.
The skill tools read their store from it (see [Skill Authoring](../guides/SKILL_AUTHORING.md)).

## Backends

`Raxol.Agent.Backend.Catalog` declares every backend. `Backend.Selector`, the resolver and
`ExecutorConfig.backend()` are derived from it.

| Harness | Backend |
| --- | --- |
| `:anthropic`, `:openai`, `:kimi`, `:ollama`, `:lm_studio`, `:llm7`, `:longcat`, `:deepseek`, `:openrouter` | `Backend.HTTP` (SSE streaming) |
| `:lumo` | `Backend.Lumo` |
| `:mock` | `Backend.Mock` |

`select/1` returns `{:error, {:unknown_backend, harness}}` for a harness the catalog does not
declare. Without `:provider`, `Backend.HTTP` detects the provider from `:base_url`: `anthropic`
selects Anthropic, `ollama` selects Ollama, `moonshot` selects Kimi, and anything else is treated
as OpenAI-compatible.

### Credentials

`Raxol.Agent.Backend.Resolver.resolve/1` turns the environment into an `ExecutorConfig`.
`Stream` calls it when given `auto_provider: true` and no `:executor`.

- **Named provider.** The key is the first found of: the `:api_key` option; a 1Password
  reference (from the store or `RAXOL_<HARNESS>_OP`); the provider's environment variable. If none
  is found, the result is `{:no_key, harness}`. `:ollama`, `:lm_studio`, `:llm7` and `:mock` need
  no key.
- **No provider.** The resolver walks the catalog and takes the first provider it can use.
  Providers billed in API credits, and the generic `AI_API_KEY` endpoint, are skipped unless
  `RAXOL_ALLOW_PAID_API` is `1`, `true`, `TRUE` or `yes`. If nothing is found, the result is
  `:no_provider`, and `Stream` falls back to its `:backend` option (default `Backend.Mock`).

The store is `~/.raxol/providers.json` (or `$RAXOL_PROVIDERS`). It holds `op://` references,
never keys, and is written with mode 0600. A store that is not owned by this account, or that is
writable by group or others, is refused.

```elixir
Raxol.Agent.Setup.connect_ref(:anthropic, %{op_ref: "op://Vault/Item/api_key"})
Raxol.Agent.Setup.remove(:anthropic)
```

`connect_key/3` stores a raw key in a new 1Password item first. `status/0` is what `raxol doctor`
prints under `providers`.

## Authorization (ALLOW/ASK/DENY)

`Raxol.Agent.Authorization.Engine` is a pure reducer over `Policy` structs. Deny takes precedence
over ask, and ask over allow. An ASK that is remembered auto-allows within its scope (`:once`,
`:session` or `:root`). A host calls `Engine.evaluate/4` and holds the state, as `raxol_broker`
does. The LLM tool-call path does not consult it: there, `ToolPolicy` decides.

## Conversation log

`Raxol.Agent.Conversation` is an append-only item log. Nothing records turns into it
automatically.

- `Item`: an immutable typed entry with id `"<conversation_id>:<seq>"`.
- `Store`: a behaviour with cursor pagination. `Store.ETS` is the shipped adapter.
- `Log`: a GenServer that adds subscriber fan-out. `subscribe/3` returns a snapshot and registers
  the subscriber in one call, so no item is missed or duplicated.

## Examples

```bash
cd packages/raxol_agent
mix run examples/agents/react_agent.exs   # tools + ReAct, Mock backend without a key
mix run examples/agents/agent_team.exs    # coordinator + workers
```

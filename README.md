# Raxol agent

A Raxol agent is a supervised BEAM process that can hold money and cannot
spend it outside a policy it did not write. The model proposes; the agent
checks the policy, writes the journal, then acts or refuses.

Built on the [Raxol](https://github.com/DROOdotFOO/raxol) runtime, which the
packages here take from Hex.

## Packages

| Package | Role |
| --- | --- |
| `raxol_agent` | Sessions, teams, scheduling, policy, the spend gate |
| `raxol_payments` | Payment rails behind per-rail caps and a ledger |
| `raxol_broker` | Fail-closed brokerage policy and a reviewed order path |
| `raxol_earn` | Agent Commerce Protocol seller and solver |
| `raxol_web3` | Guarded chain reads |
| `raxol_console` | Console runtime: the gateway handler and the scheduler |
| `raxol_cli` | The `raxol` binary and its npm wrapper |
| `raxol_agent_client_protocol` | Agent Client Protocol codec and transports |

## Docs

- [Agent Framework](docs/features/AGENT_FRAMEWORK.md): agents, tools, backends, credentials
- [Agentic Commerce](docs/features/AGENTIC_COMMERCE.md): wallets, protocols, spending limits
- [Editor ACP](docs/features/EDITOR_ACP.md): serving an agent to an editor
- [Skill Authoring](docs/guides/SKILL_AUTHORING.md)
- [Architecture decisions](docs/adr/)

## Development

The toolchain is pinned in `mise.toml`. Each package is its own Mix project:

```bash
cd packages/raxol_agent
mix deps.get
mix test
```

To build against a checkout of the runtime instead of its Hex releases, set
`RAXOL_PATH` to that checkout (absolute, or relative to this repository's
root):

```bash
RAXOL_PATH=../raxol mix deps.get
```

## License

MIT. See [LICENSE.md](LICENSE.md).

# Changelog

All notable changes to `raxol_web3` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Changed

- **Visible to MCP clients: the thirteen `Raxol.Web3.MCP.Tools` tools answer
  JSON text instead of Elixir `inspect` output.** Tool names, argument
  schemas, annotations and the read-only guarantee are unchanged.
  - A result is a JSON object keyed by the contract's field names. `balance`,
    `value`, `fee` and `amount` are always decimal strings, and so is any
    other integer past 2^53. `web3_resolve_name` answers `{"account": ...}`
    and `web3_read_contract` answers `{"value": ...}`.
  - An error is `Error: {"code", "detail", "hint"}`. `hint` is a fixed
    sentence that says what to do next. The `Error: ` prefix is
    `Raxol.MCP.Server`'s.
  - `no_backend` lists the served chains under `"chains"`. A name where an
    account belongs gets a hint to call `web3_resolve_name` first. A
    malformed EVM transaction hash is refused locally as `invalid_argument`.

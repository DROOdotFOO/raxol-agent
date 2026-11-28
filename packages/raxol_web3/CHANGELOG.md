# Changelog

All notable changes to `raxol_web3` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Changed

- **Visible to MCP clients: the thirteen `Raxol.Web3.MCP.Tools` tools now answer
  JSON text instead of Elixir `inspect` output.** A client that scraped the old
  `%{unit: :block, ...}` text must parse JSON instead. Tool names, argument
  schemas, annotations and the read-only guarantee are unchanged.
  - A result is a JSON object (`Raxol.Web3.MCP.JSON`): keys are the contract's
    field names as strings (`"contract?"`, `"finalized_height"`), atoms are
    strings, and timestamps are ISO 8601. `balance`, `value`, `fee` and
    `amount` are decimal strings at every size, so a wei amount never loses
    digits and one field never has two JSON types; any other integer past
    2^53 is a decimal string too. `web3_resolve_name` answers
    `{"account": "evm:0x..."}` and `web3_read_contract` answers
    `{"value": "0x..."}`, as `Raxol.Agent.Actions.Web3` already wraps them.
  - An error is `Error: {"code", "detail", "hint"}` (`Raxol.Web3.MCP.Error`).
    `code` and `detail` are the values the old text showed; `hint` is a fixed
    sentence that says what to do next and carries no upstream text. The
    `Error: ` prefix is `Raxol.MCP.Server`'s and cannot be changed from here.
  - `no_backend` lists the chains the router serves under `"chains"`.
  - An `unsupported_account_ref` for a value that looks like a name
    (`"vitalik.eth"`) says to call `web3_resolve_name` first. The name is not
    resolved for the caller, so one call stays one read.
  - `web3_get_transaction` on an `eip155:` chain refuses a hash that is not
    `0x` plus 64 hex characters as `invalid_argument` / `"hash"` before any
    request. It was sent upstream and came back as `http` / `422`.
  - A `timeout` says it was a timeout and that a retry or a narrower query may
    work.

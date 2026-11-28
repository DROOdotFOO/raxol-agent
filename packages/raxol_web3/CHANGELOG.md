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
  - An error is `Error: {"code", "detail", "hint"}`. `code` and `detail`
    are the values the old text showed. `hint` is a fixed sentence that says
    what to do next. The `Error: ` prefix is `Raxol.MCP.Server`'s.
  - `no_backend` lists the served chains under `"chains"`. A name where an
    account belongs gets a hint to call `web3_resolve_name` first; behind an
    `evm:` prefix, to drop the prefix and pass the name alone. A malformed EVM
    transaction hash is refused locally as `invalid_argument`.
  - `no_backend` on a deployment that serves no chains says so instead of
    pointing at an empty `"chains"`.
  - A backend answer that is not an object, or not the account or hex value
    the tool promises, is `decode_failed` / `"result"` instead of a non-object
    result.
- **Visible to MCP clients: the three `Raxol.Web3.MCP.FXTools` tools
  (`web3_fx_*`) answer the same way:** JSON text, and `Error: {"code",
  "detail", "hint"}`. Prices and rates are decimal strings with every digit
  the source gave. An `invalid_argument` hint for `symbol`, `corridor`,
  `sort`, `limit` or `offset` names the accepted values.
  `Raxol.Agent.Actions.FX` still answers Elixir terms.
- **Visible to MCP clients: when every source for a chain fails, the error
  is the first source's fault, not the last source's.** A bare HTTP status,
  an unclassified refusal or an answer only that source would give (such as a
  cursor another source minted) from a fallback no longer stands in for it,
  so a client is not told to check arguments or a cursor that were fine, and
  the tool's breaker counts the fault. An answer every source would give
  (`not_found`, a reference of the wrong family, a missing argument) still
  stands.
- **Visible to MCP clients: a page-two request goes to the source that
  minted its cursor, and a source whose base URL does not parse is skipped.**
  A cursor whose source is paused answers `breaker_open` ("Retry later"),
  where it answered `invalid_cursor`; a cursor no configured source minted is
  still `invalid_cursor`. A misconfigured first source no longer answers
  `blocked` on every read: the next source answers, the operator is warned at
  most once an hour per source, and a client that does see it gets a hint
  that names a misconfiguration rather than an outbound policy.

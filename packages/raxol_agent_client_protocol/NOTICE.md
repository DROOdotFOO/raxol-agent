# Provenance & attribution

This package is MIT-licensed (see `LICENSE.md`).

## Ported code

The schema, type and serialization layer is ported from
[`f1729/agent_client_protocol`](https://github.com/f1729/agent-client-protocol-elixir),
with defects fixed and modules restructured under `Raxol.AgentClientProtocol.*`.
Files carrying ported code note this in their moduledoc, and so do the
repository's tests ported from its test suite. That project's licence:

```text
MIT License

Copyright (c) 2025 f1729

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## The ACP JSON Schema (not shipped)

The repository keeps the official ACP JSON Schema (Apache-2.0) as a validation
oracle for its tests. It is excluded from the Hex package (`mix.exs` `:files`).

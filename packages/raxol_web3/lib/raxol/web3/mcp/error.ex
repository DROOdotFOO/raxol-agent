defmodule Raxol.Web3.MCP.Error do
  @moduledoc """
  A served tool's error: the closed taxonomy's code and datum, plus a hint
  that says what to do next.

  ## The shape

      {"code": "no_backend", "detail": null,
       "hint": "No backend serves this chain. ...",
       "chains": ["eip155:1"]}

  `code` and `detail` are `Raxol.Web3.Serialize.error/1`'s, unchanged, so a
  client that branched on them keeps working. `hint` is always present, a
  string or `null`. `chains` appears only on `no_backend`, and names the
  chains the router does serve.

  ## Why a hint is not upstream text

  ADR-0038 decision 6 keeps upstream bytes out of every error, and this keeps
  that rule: a hint is one of the fixed sentences below, chosen by the code
  and its datum, and `chains` is the operator's own router configuration. No
  argument the caller sent is echoed either.

  ## Why the struct renders itself as JSON

  `Raxol.MCP.Server` renders a callback's `{:error, reason}` as `"Error: " <>
  inspect(reason)`, with no way for a tool to supply its own text, so the
  `Inspect` implementation below IS the error text a client receives: `Error:
  {"code":...}`. The struct keeps the Elixir terms (`detail: :not_found`) so
  that `Raxol.Web3.MCP.Tools.fault?/1`, which `Raxol.MCP.Registry` calls with
  this value, reads it as it read the plain map before.
  """

  alias Raxol.Web3.MCP.JSON
  alias Raxol.Web3.Serialize

  @enforce_keys [:code]
  defstruct code: nil, detail: nil, hint: nil, chains: nil

  @type t :: %__MODULE__{
          code: String.t(),
          detail: term(),
          hint: String.t() | nil,
          chains: [String.t()] | nil
        }

  @typedoc """
  What the tool knew when the call failed: the chains its router serves, and
  the raw `account` argument when the tool takes one.
  """
  @type context :: %{optional(:chains) => [String.t()], optional(:account) => term()}

  @families ~s(Prefix a non-EVM account with its family: "tron:", "solana:", ) <>
              ~s("party:" or "aztec:".)

  @doc "Build the served error for a taxonomy reason."
  @spec new(term(), context()) :: t()
  def new(reason, context \\ %{}) do
    %{code: code, detail: detail} = Serialize.error(reason)

    %__MODULE__{
      code: code,
      detail: detail,
      hint: hint(code, detail, context),
      chains: chains(code, context)
    }
  end

  @doc "The error as JSON-safe data, in the shape the moduledoc gives."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{"code" => error.code, "detail" => JSON.safe(error.detail), "hint" => error.hint}
    |> put_chains(error.chains)
  end

  @doc "The error as JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error), do: error |> to_map() |> Jason.encode!()

  defp put_chains(map, nil), do: map
  defp put_chains(map, chains), do: Map.put(map, "chains", chains)

  defp chains("no_backend", context), do: context |> Map.get(:chains, []) |> Enum.sort()
  defp chains(_code, _context), do: nil

  # -- Hints -----------------------------------------------------------------

  defp hint("no_backend", _detail, _context),
    do:
      "No backend serves this chain. Call again with one of the CAIP-2 references in " <>
        "\"chains\"."

  defp hint("missing_argument", name, _context),
    do: "The required argument \"#{name}\" is missing."

  defp hint("invalid_argument", "chain", _context),
    do: ~s(The chain must be a CAIP-2 string, e.g. "eip155:1" for Ethereum mainnet.)

  defp hint("invalid_argument", "hash", _context),
    do:
      "Not a transaction hash this chain uses: an EVM transaction hash is \"0x\" " <>
        "followed by 64 hex characters."

  defp hint("invalid_argument", "number", _context),
    do:
      "The block number must be a non-negative integer, a 0x quantity, or one of " <>
        "latest, earliest, pending, safe, finalized."

  defp hint("invalid_argument", name, _context),
    do: "The argument \"#{name}\" has the wrong type; see the tool's inputSchema."

  defp hint("unsupported_account_ref", _detail, context) do
    if name?(Map.get(context, :account)),
      do:
        "The account looks like a name, not an address. Call web3_resolve_name with " <>
          "this name and the same chain first, then pass the account it returns.",
      else: "The account is not an address this chain uses. " <> @families
  end

  defp hint("unsupported", _callback, _context),
    do: "No backend registered for this chain answers this tool."

  defp hint("unsupported_chain", _detail, _context),
    do: "The source behind this chain does not serve it."

  defp hint("invalid_cursor", _detail, _context),
    do:
      "The cursor is not valid here. Pass it exactly as the previous page of the same " <>
        "tool on the same chain returned it, or omit it for the first page."

  defp hint("timeout", stage, _context),
    do:
      "This was a timeout: the source did not answer in time (stage: #{stage}). A retry " <>
        "may work. If it times out again the query is likely too large for this source; " <>
        "try a narrower one, such as a more specific tool or a later page by cursor."

  defp hint("rate_limited", ms, _context),
    do: "The source is rate limiting this client. Retry after #{ms} ms."

  defp hint("breaker_open", _origin, _context),
    do: "The source failed repeatedly and is paused. Retry in a minute."

  defp hint("transport", _detail, _context),
    do: "The connection to the source failed. A retry may work."

  defp hint("dns_failed", _origin, _context),
    do: "The source's host name did not resolve. A retry later may work."

  defp hint("too_large", limit, _context),
    do: "The answer was larger than the #{limit}-byte limit. Try a narrower query."

  defp hint("decode_failed", _tag, _context),
    do: "The source answered in a shape this tool could not read. A retry may work."

  defp hint("unencodable_result", _detail, _context),
    do: "The source answered with data that cannot be written as JSON."

  defp hint("http", 404, _context), do: "The source has no such record (HTTP 404)."

  defp hint("http", status, _context) when status in [408, 429] or status >= 500,
    do: "The source failed with HTTP #{status}. A retry may work."

  defp hint("http", status, _context) when is_integer(status),
    do: "The source refused the request with HTTP #{status}. Check the arguments."

  defp hint("upstream_refused", :not_found, _context), do: "The source has no such record."

  defp hint("upstream_refused", :auth, _context),
    do: "The source requires a credential this deployment does not hold."

  defp hint("upstream_refused", :rate_limit, _context),
    do: "The source's quota for this deployment is spent. Retry later."

  defp hint("upstream_refused", _detail, _context),
    do: "The source refused the request without saying why."

  defp hint("source_unavailable", _detail, _context),
    do: "The source is no longer available at its configured address."

  defp hint("blocked", _detail, _context),
    do: "This deployment's outbound policy refuses the source's address."

  defp hint(_code, _detail, _context), do: nil

  # A dot and no family prefix is how a name differs from every account form
  # this surface reads: an EVM address, a Tron or Solana key and a Canton
  # party id carry no dot, and every non-EVM family is prefixed.
  defp name?(account) when is_binary(account) do
    String.contains?(account, ".") and not String.contains?(account, ":") and
      not String.starts_with?(account, "0x")
  end

  defp name?(_account), do: false

  defimpl Inspect do
    def inspect(error, _opts), do: Raxol.Web3.MCP.Error.to_json(error)
  end

  defimpl Jason.Encoder do
    def encode(error, opts), do: error |> Raxol.Web3.MCP.Error.to_map() |> Jason.Encode.map(opts)
  end
end

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

  alias Raxol.Web3.HTTP
  alias Raxol.Web3.MCP.Result
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

  @retry_narrower "A retry may work. If it times out again, ask for less: a more " <>
                    "specific tool or a later page."

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
    %{"code" => error.code, "detail" => Result.safe(error.detail), "hint" => error.hint}
    |> put_chains(error.chains)
  end

  @doc """
  The error as JSON text. Total: it is called from `Inspect`, whose output
  `Raxol.MCP.Server` sends outside `Raxol.MCP.Registry`'s `rescue`, so a raise
  here would put an `Inspect.Error` with a struct dump and a stack trace in
  front of a model. A datum JSON cannot hold (a binary that is not UTF-8, a
  pid) is answered with the code, a null detail and the hint instead.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error) do
    [
      to_map(error),
      %{"code" => error.code, "detail" => nil, "hint" => error.hint},
      %{"code" => "error", "detail" => nil, "hint" => nil}
    ]
    |> Enum.find_value(&encoded/1)
  end

  defp encoded(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      {:error, _reason} -> nil
    end
  end

  defp put_chains(map, nil), do: map
  defp put_chains(map, chains), do: Map.put(map, "chains", chains)

  defp chains("no_backend", context), do: context |> Map.get(:chains, []) |> Enum.sort()
  defp chains(_code, _context), do: nil

  # -- Hints -----------------------------------------------------------------

  # The list to pick from is only offered when there is one: a router with no
  # chains makes every chain reference fail, and an error built without the
  # router's chains cannot say which exist.
  defp hint("no_backend", _detail, context) do
    case Map.fetch(context, :chains) do
      {:ok, []} ->
        "This deployment serves no chains, so no chain reference will work. Its " <>
          "operator has to configure a backend."

      {:ok, _chains} ->
        "No backend serves this chain. Call again with one of the CAIP-2 references in " <>
          "\"chains\"."

      :error ->
        "No backend serves this chain."
    end
  end

  # Every clause that interpolates its datum is guarded on the type it
  # expects, and an argument name only when it is printable, because
  # `Raxol.Web3.Serialize.error/1` admits a nested map or any binary there and
  # a hint must be total. The datum-free sentence after each one is the
  # fallthrough.
  defp hint("missing_argument", name, _context) when is_binary(name) do
    if printable?(name),
      do: "The required argument \"#{name}\" is missing.",
      else: "A required argument is missing."
  end

  defp hint("missing_argument", _detail, _context), do: "A required argument is missing."

  defp hint("invalid_argument", "chain", _context),
    do: ~s(The chain must be a CAIP-2 string, e.g. "eip155:1" for Ethereum mainnet.)

  defp hint("invalid_argument", "hash", _context),
    do: ~s(An EVM transaction hash is "0x" plus 64 hex characters.)

  defp hint("invalid_argument", "number", _context),
    do:
      "The block number must be a non-negative integer, a 0x quantity, or one of " <>
        Enum.join(Serialize.block_tags(), ", ") <> "."

  defp hint("invalid_argument", name, _context) when is_binary(name) do
    if printable?(name),
      do: "The argument \"#{name}\" has the wrong type; see the tool's inputSchema.",
      else: "An argument has the wrong type; see the tool's inputSchema."
  end

  defp hint("invalid_argument", _detail, _context),
    do: "An argument has the wrong type; see the tool's inputSchema."

  defp hint("unsupported_account_ref", _detail, context) do
    if name?(Map.get(context, :account)),
      do:
        "This looks like a name. Call web3_resolve_name with it and the same chain, " <>
          "then pass the account it returns.",
      else: "The account is not an address this chain uses. " <> families()
  end

  defp hint("unsupported", _callback, _context),
    do: "No backend registered for this chain answers this tool."

  defp hint("unsupported_chain", _detail, _context),
    do: "The source behind this chain does not serve it."

  defp hint("invalid_cursor", _detail, _context),
    do:
      "Pass the cursor exactly as the previous page of this tool on this chain " <>
        "returned it, or omit it for the first page."

  defp hint("timeout", stage, _context) when is_atom(stage) and not is_nil(stage),
    do: "The source timed out (stage: #{stage}). " <> @retry_narrower

  defp hint("timeout", _detail, _context),
    do: "The source timed out. " <> @retry_narrower

  defp hint("rate_limited", ms, _context) when is_integer(ms),
    do: "The source is rate limiting this client. Retry after #{ms} ms."

  defp hint("rate_limited", _detail, _context),
    do: "The source is rate limiting this client. Retry later."

  defp hint("breaker_open", _origin, _context),
    do: "The source failed repeatedly and is paused. Retry later."

  defp hint("transport", _detail, _context),
    do: "The connection to the source failed. A retry may work."

  defp hint("dns_failed", _origin, _context),
    do: "The source's host name did not resolve. Retry later."

  defp hint("too_large", limit, _context) when is_integer(limit),
    do: "The answer was larger than the #{limit}-byte limit. Try a narrower query."

  defp hint("too_large", _detail, _context),
    do: "The answer was larger than the size limit. Try a narrower query."

  defp hint("decode_failed", _tag, _context),
    do: "The source answered in a shape this tool could not read. A retry may work."

  defp hint("unencodable_result", _detail, _context),
    do: "The source answered with data that cannot be written as JSON."

  # Which statuses a retry can help is `Raxol.Web3.HTTP.unhealthy_status?/1`'s
  # call, the same one the router's failover and `Tools.fault?/1` make, so it
  # is asked rather than restated here. Within each class the wording says
  # whose problem it is: 401 and 403 are the source refusing this deployment,
  # and only a status about the request itself says to check the arguments.
  defp hint("http", 404, _context), do: "The source has no such record (HTTP 404)."

  defp hint("http", status, _context) when is_integer(status) do
    if HTTP.unhealthy_status?(status), do: retry_hint(status), else: final_hint(status)
  end

  defp hint("http", _detail, _context),
    do: "The source answered with an HTTP status this tool cannot use."

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

  defp retry_hint(403),
    do:
      "The source refused this deployment (HTTP 403). Changing the arguments will " <>
        "not help. Retry later."

  defp retry_hint(status), do: "The source failed with HTTP #{status}. A retry may work."

  defp final_hint(401),
    do:
      "The source needs a credential this deployment does not hold (HTTP 401). " <>
        "Changing the arguments will not help."

  defp final_hint(status) when status in 400..499,
    do: "The source refused the request with HTTP #{status}. Check the arguments."

  defp final_hint(status),
    do: "The source answered with HTTP #{status}, which this tool cannot use."

  # A dot and no family prefix is how a name differs from every account form
  # this surface reads: an EVM address, a Tron or Solana key and a Canton
  # party id carry no dot, and every non-EVM family is prefixed. `"evm:"` is
  # the one prefix a name can sit behind, because an unprefixed value already
  # means EVM (`Raxol.Web3.Serialize.account_ref/1`), so it is read past.
  defp name?("evm:" <> account), do: name?(account)

  defp name?(account) when is_binary(account) do
    String.contains?(account, ".") and not String.contains?(account, ":") and
      not String.starts_with?(account, "0x")
  end

  defp name?(_account), do: false

  # Derived from `Raxol.Web3.Serialize.tags/0`, so a family that lands there
  # is named here without an edit.
  defp families do
    {last, rest} =
      Serialize.tags() |> List.delete("evm") |> Enum.map(&~s("#{&1}:")) |> List.pop_at(-1)

    "Prefix a non-EVM account with its family: " <> Enum.join(rest, ", ") <> " or " <> last <> "."
  end

  defp printable?(name), do: byte_size(name) <= 64 and String.printable?(name)

  defimpl Inspect do
    def inspect(error, _opts), do: Raxol.Web3.MCP.Error.to_json(error)
  end

  # Both implementations go through `to_json/1`, so neither can raise. The
  # encoder returns the finished text, which `Jason` inserts as-is.
  defimpl Jason.Encoder do
    def encode(error, _opts), do: Raxol.Web3.MCP.Error.to_json(error)
  end
end

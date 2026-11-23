defmodule Raxol.Agent.McpHeaders do
  @moduledoc """
  Resolve a remote MCP server's auth headers, gated on where the spec came
  from.

  A header value is either a literal or a reference:

      "Bearer sk-live-..."        # literal
      "Bearer ${env:INTEL_TOKEN}" # env reference, interpolated
      "${op://Employee/Intel/token}"
      "op://Employee/Intel/token" # bare 1Password reference

  References resolve at connect time, `op://` through
  `Raxol.Agent.Backend.Credentials.read_ref/2`. A literal is accepted and warned
  about once per server.

  ## Provenance

  A workspace `.mcp.json` is repository content. Resolving its references would
  let a cloned repository read a named env var or 1Password item and POST it to a
  host it chose. So:

    * a `:user` spec (`~/.raxol/mcp.json`, or an explicit operator flag)
      resolves references normally;
    * a `:workspace` spec may carry a `url`, but its header values must be
      literals or allowlisted references. Anything else is refused with
      `{:workspace_header_reference, name}`; the server is skipped and the
      refusal logged once.

  Nothing in this package reads `.mcp.json`; the host that parses one tags the
  spec `:workspace`.

  ## Allowlist

  `$RAXOL_MCP_HEADER_ALLOWLIST`, or `~/.raxol/mcp_headers.json`, never a
  workspace file:

      {"Authorization": ["${env:INTEL_TOKEN}", "op://Employee/Intel/token"]}

  Header names match case-insensitively; both name and reference must match
  (the repository picks the header name too). A missing or malformed file is an
  empty allowlist. `Raxol.Agent.OperatorFile` vets the path: with no home
  directory there is no allowlist, and a file not owned by this account, or
  group- or other-writable, is refused and logged.

  ## No leaks

  A resolved value is returned to the caller only: never logged, measured,
  cached, put in an error term or persisted. Errors carry the header name and an
  atom reason; `op` failures are `{:op_read_failed, exit_code}`.
  """

  require Logger

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.OperatorFile

  @allowlist_env "RAXOL_MCP_HEADER_ALLOWLIST"
  @allowlist_filename "mcp_headers.json"
  @label "mcp header allowlist"

  # `${env:NAME}` / `${op://PATH}` anywhere in a value. A bare `op://PATH` as
  # the whole value is also a reference: it is the form `providers.json` and
  # the `op` CLI both use, so an operator will paste it.
  @ref_re ~r/\$\{(env:[^{}]+|op:\/\/[^{}]+)\}/

  @type header :: {String.t(), String.t()}
  @type reason ::
          {:workspace_header_reference, String.t()}
          | {:header_unresolved, String.t(), atom() | {atom(), integer()}}

  @doc """
  Resolve every header value for one server.

  Options:

    * `:source` -- `:workspace` (default, the strict side: an unknown
      provenance is treated as the untrusted one) or `:user`.
    * `:server` -- the server name, used only in the literal-value warning.

  Returns `{:ok, headers}` with the same names in the same order, or
  `{:error, reason}` on the first header that cannot be resolved under the
  spec's provenance. Neither the returned values nor any failure reason is
  logged.
  """
  @spec resolve([header()], keyword()) :: {:ok, [header()]} | {:error, reason()}
  def resolve(headers, opts \\ []) when is_list(headers) do
    source = Keyword.get(opts, :source, :workspace)
    allowed = allowed(source, headers)

    headers
    |> Enum.reduce_while({[], []}, fn header, {resolved, literals} ->
      case resolve_header(header, allowed) do
        {:ok, value} -> {:cont, {[{elem(header, 0), value} | resolved], literals}}
        :literal -> {:cont, {[header | resolved], [elem(header, 0) | literals]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> finish(Keyword.get(opts, :server))
  end

  # The allowlist file is read only when a reference is actually present. A
  # server configured entirely with literals asks for no permission, and
  # reading the control anyway would log a refusal ("no home directory", "the
  # file is group-writable") about a grant nothing needed.
  defp allowed(:user, _headers), do: :all

  defp allowed(_workspace, headers) do
    if Enum.any?(headers, fn {_name, value} -> references(value) != [] end),
      do: allowlist(),
      else: %{}
  end

  defp finish({:error, _} = err, _server), do: err

  defp finish({resolved, literals}, server) do
    warn_literals(server, literals)
    {:ok, Enum.reverse(resolved)}
  end

  # One line per server, not per header: a server configured entirely with
  # literals is one operator decision, not N.
  defp warn_literals(_server, []), do: :ok

  defp warn_literals(server, literals) do
    names = literals |> Enum.reverse() |> Enum.join(", ")

    Logger.warning(fn ->
      "mcp headers: server #{inspect(server)} carries literal header values (#{names}); " <>
        "prefer ${env:VAR} or op://... in the user-level config so no secret sits in a config file"
    end)
  end

  defp resolve_header({name, value}, allowed) do
    case references(value) do
      [] -> :literal
      refs -> resolve_refs(name, value, refs, allowed)
    end
  end

  defp resolve_refs(name, value, refs, allowed) do
    if permitted?(refs, name, allowed) do
      expand(name, value, refs)
    else
      {:error, {:workspace_header_reference, name}}
    end
  end

  defp permitted?(_refs, _name, :all), do: true

  defp permitted?(refs, name, allowed) do
    permitted = Map.get(allowed, String.downcase(name), MapSet.new())
    Enum.all?(refs, fn {kind, arg, _token} -> MapSet.member?(permitted, {kind, arg}) end)
  end

  # Substitute each reference's token with its secret. A bare `op://` value is
  # its own token, so the whole value is replaced.
  defp expand(name, value, refs) do
    Enum.reduce_while(refs, {:ok, value}, fn ref, {:ok, acc} ->
      case read(ref) do
        {:ok, secret} -> {:cont, {:ok, String.replace(acc, token(ref), secret)}}
        {:error, reason} -> {:halt, {:error, {:header_unresolved, name, reason}}}
      end
    end)
  end

  defp token({_kind, _arg, token}), do: token

  defp read({:env, name, _token}) do
    case System.fetch_env(name) do
      {:ok, ""} -> {:error, :env_empty}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :env_not_set}
    end
  end

  defp read({:op, path, _token}) do
    case Credentials.read_ref("op://" <> path) do
      {:ok, secret} -> {:ok, secret}
      # `op`'s own stderr is upstream text; keep the exit code, drop the text.
      {:error, {:op_failed, code, _text}} -> {:error, {:op_read_failed, code}}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _other} -> {:error, :op_read_failed}
    end
  end

  @doc """
  The references in one header value, as `{:env | :op, argument, token}`.

  `[]` means the value is a literal. Exposed because "is this a reference"
  is the question both the provenance gate and the allowlist parser ask.
  """
  @spec references(String.t()) :: [{:env | :op, String.t(), String.t()}]
  def references("op://" <> path = value) when path != "", do: [{:op, path, value}]

  def references(value) when is_binary(value) do
    @ref_re
    |> Regex.scan(value)
    |> Enum.map(fn [token, inner] -> reference(inner, token) end)
  end

  def references(_other), do: []

  defp reference("env:" <> name, token), do: {:env, name, token}
  defp reference("op://" <> path, token), do: {:op, path, token}

  @doc """
  The allowlist path (`$RAXOL_MCP_HEADER_ALLOWLIST` or
  `~/.raxol/mcp_headers.json`), or nil when there is neither an override nor
  a home directory to put it in.
  """
  @spec allowlist_path() :: String.t() | nil
  def allowlist_path, do: OperatorFile.path(@allowlist_env, @allowlist_filename)

  @doc """
  The operator's header allowlist, as `%{downcased_header_name => MapSet of
  {kind, argument}}`.

  A missing, unreadable, untrusted or malformed file is `%{}`: no workspace
  reference resolves. Failing closed on a broken allowlist is the only safe
  direction, since the file exists to withhold permission. "Untrusted" is
  `Raxol.Agent.OperatorFile`'s judgement: no home and no override, a foreign
  owner, or a group/other-writable mode.
  """
  @spec allowlist() :: %{optional(String.t()) => MapSet.t()}
  def allowlist do
    with {:ok, raw} <- OperatorFile.read(@allowlist_env, @allowlist_filename, @label),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      Map.new(decoded, fn {name, refs} -> {String.downcase(name), allowed_refs(refs)} end)
    else
      _ -> %{}
    end
  end

  defp allowed_refs(refs) when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&references/1)
    |> MapSet.new(fn {kind, arg, _token} -> {kind, arg} end)
  end

  defp allowed_refs(_other), do: MapSet.new()
end

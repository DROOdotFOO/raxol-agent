defmodule Raxol.Web3.Scope do
  @moduledoc """
  The identity of one upstream source: its full base URL, not just its host.

  `Raxol.Web3.Origin` keys health, rate limits and breakers, which describe a
  server and are right per host. A response cache and a pagination cursor
  describe what one source said, and one host can front several sources: a
  provider that routes chains by path (`/eth`, `/polygon`), or tenants by a
  key segment (`/v2/KEY`, `?api-key=`). Keyed by host, two of those would
  share cache entries and accept each other's cursors.

  So the scope is the base URL in full (scheme, user info, host, port, path
  and query, normalized so a trailing slash or default port does not split
  one source in two) together with the request headers a handle sends, since
  a credential or a tenant can travel in a header as well. It is an HMAC under the node's cursor key
  (`Raxol.Web3.Tables.cursor_key/0`), not a plain digest: a cursor carries it
  to the caller, and a bare hash of a URL whose secret is a short path
  segment would be an offline guessing oracle for that secret. It is kept in
  no table and cannot be turned back into a URL.

  It costs a call to `Raxol.Web3.Tables`, so a backend computes it once, when
  its handle is built, and carries it on the handle.
  """

  alias Raxol.Web3.Tables

  @type t :: String.t()

  @id_bytes 16

  @doc """
  The scope of a base URL and the headers sent with it.

  Header names compare case-insensitively and the list is sorted by name, so
  the order an operator wrote them in does not split one source in two.
  """
  @spec id(String.t() | URI.t(), [{String.t(), String.t()}]) :: t()
  def id(url, headers \\ []) do
    input = "raxol_web3.scope\0" <> canonical(url) <> "\0" <> canonical_headers(headers)

    :crypto.mac(:hmac, :sha256, Tables.cursor_key(), input)
    |> binary_part(0, @id_bytes)
    |> Base.url_encode64(padding: false)
  end

  @doc "The scope of a base URL and the `:headers` in a handle's `:http_opts`."
  @spec of(String.t() | URI.t(), keyword()) :: t()
  def of(url, http_opts), do: id(url, Keyword.get(http_opts, :headers, []))

  defp canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} ->
      {String.downcase(to_string(name), :ascii), to_string(value)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> :erlang.term_to_binary()
  end

  defp canonical(url) do
    %URI{} = uri = URI.parse(url)
    # ASCII only: Unicode case folding maps the Kelvin sign onto `k`, which
    # would merge two hosts that dial differently.
    scheme = uri.scheme && String.downcase(uri.scheme, :ascii)
    host = uri.host && String.downcase(uri.host, :ascii)
    userinfo = if uri.userinfo, do: uri.userinfo <> "@", else: ""
    path = String.trim_trailing(uri.path || "", "/")
    query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query

    "#{scheme}://#{userinfo}#{host}:#{uri.port}#{path}#{query}"
  end
end

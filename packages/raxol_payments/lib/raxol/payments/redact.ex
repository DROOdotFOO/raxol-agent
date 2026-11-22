defmodule Raxol.Payments.Redact do
  @moduledoc false
  # Text for logs and errors that names what a value is without carrying the
  # parts of it that may be credentials: a URL's userinfo, path and query
  # (`?key=`), or a caller's own metadata.

  @doc """
  `scheme://host[:port]` of `url`, lowercased, IPv6 bracketed, or a
  placeholder when it has no plain host. Never its userinfo, path or query.

  This is display text. `Xochi.ReadTokenStore.origin/1` builds the same
  origin as a store key and raises on a URL it cannot key.
  """
  @spec url(term()) :: String.t()
  def url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) and host != "" ->
        if host =~ ~r/\A[A-Za-z0-9._:\-]+\z/,
          do: origin(scheme, host, port),
          else: "<url with an invalid host>"

      _ ->
        "<url without a host>"
    end
  end

  def url(_other), do: "<not a string>"

  @doc "Whether `value` parses as a URL with a scheme and a host."
  @spec url?(String.t()) :: boolean()
  def url?(value) when is_binary(value) do
    match?(
      %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) and h != "",
      URI.parse(value)
    )
  end

  defp origin(scheme, host, port) do
    scheme = String.downcase(scheme || "?")
    host = String.downcase(host)
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    port = if port in [nil, URI.default_port(scheme)], do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port}"
  end
end

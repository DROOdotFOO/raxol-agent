defmodule Raxol.Web3.Backend.Cache do
  @moduledoc """
  Composes a response-cache entry onto `Raxol.Web3.HTTP` options.

  The key is a fragment the backend builds from its own path or method and
  parameters, never from an assembled URL, which is what keeps a credential
  out of a cache key by construction. `Raxol.Web3.HTTP` prefixes it with the
  origin id.
  """

  alias Raxol.Web3.TTL

  @doc """
  Add `cache: [key: key, ttl_ms: TTL.for(class)]` to `opts`. A `nil` class is
  a request that must not be cached, and `cache?: false` is a handle that
  caches nothing; both leave `opts` untouched. Only `false` turns caching
  off: any other value caches, as the backends always read the option.
  """
  @spec opts(keyword(), term(), term(), TTL.class() | nil) :: keyword()
  def opts(opts, _cache?, _key, nil), do: opts
  def opts(opts, false, _key, _class), do: opts

  def opts(opts, _cache?, key, class),
    do: Keyword.put(opts, :cache, key: key, ttl_ms: TTL.for(class))
end

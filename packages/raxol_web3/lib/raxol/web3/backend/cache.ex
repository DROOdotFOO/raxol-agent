defmodule Raxol.Web3.Backend.Cache do
  @moduledoc """
  Composes a response-cache entry onto `Raxol.Web3.HTTP` options.

  The key is `{scope, fragment}`. The fragment is built from the backend's own
  path or method and parameters, never from an assembled URL, which keeps a
  credential out of a cache key by construction. The scope
  (`Raxol.Web3.Scope.id/1` of the handle's base URL) keeps two sources behind
  one host, told apart by path or query, from sharing entries.
  `Raxol.Web3.Cache` describes the full entry key.
  """

  alias Raxol.Web3.TTL

  @doc """
  Add `cache: [key: key, ttl_ms: TTL.for(class)]` to `opts`. A `nil` class is
  a request that must not be cached, and `cache?: false` is a handle that
  caches nothing; both leave `opts` untouched. Only `false` turns caching
  off: any other value caches, as the backends always read the option.
  """
  @spec opts(keyword(), Raxol.Web3.Scope.t(), term(), term(), TTL.class() | nil) :: keyword()
  def opts(opts, _scope, _cache?, _key, nil), do: opts
  def opts(opts, _scope, false, _key, _class), do: opts

  def opts(opts, scope, _cache?, key, class),
    do: Keyword.put(opts, :cache, key: {scope, key}, ttl_ms: TTL.for(class))
end

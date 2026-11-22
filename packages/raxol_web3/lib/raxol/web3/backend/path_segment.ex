defmodule Raxol.Web3.Backend.PathSegment do
  @max_bytes 256

  @moduledoc """
  Turns a caller-supplied id into one URL path segment, or refuses it.

  An id reaches a path from a model, so it is checked against an allowlist
  rather than a list of known-bad spellings: ASCII letters, digits, `_`, `-`
  and `:`, at most #{@max_bytes} bytes. Every id these backends take fits it (hex
  hashes and addresses, decimal block numbers, `latest`-style tags, Canton's
  `1220...` update ids). A denylist of dot segments cannot be complete: a
  proxy or server may strip `;` parameters (`..;`), trim trailing dots or
  whitespace, decode overlong UTF-8 or `%u002e`, or percent-decode more times
  than any fixed depth, and each of those turns an id into `..` and the
  request into one for the API root with the operator's key attached. With
  no `.`, `%`, `/` or `\\` admitted at all, none of them applies.

  What passes is still percent-encoded against the unreserved set, which
  leaves it unchanged except for `:`.
  """

  @doc """
  The encoded segment for `value`, or `{:invalid_argument, name}`.

  A non-negative integer is a block number and passes through as digits.
  """
  @spec encode(term(), String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_argument, String.t()}}
  def encode(value, _name) when is_integer(value) and value >= 0,
    do: {:ok, Integer.to_string(value)}

  def encode(value, name) when is_binary(value) do
    if allowed?(value),
      do: {:ok, URI.encode(value, &URI.char_unreserved?/1)},
      else: {:error, {:invalid_argument, name}}
  end

  def encode(_value, name), do: {:error, {:invalid_argument, name}}

  defp allowed?(value) when byte_size(value) in 1..@max_bytes,
    do: value =~ ~r/\A[A-Za-z0-9_:\-]+\z/

  defp allowed?(_value), do: false
end

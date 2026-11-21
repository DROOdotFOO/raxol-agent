defmodule Raxol.Broker.Redact do
  @moduledoc false
  # Reduce a failure reason or a stray message to a term that is safe to log
  # or keep. A reason from the inner MCP client can carry a stacktrace whose
  # arguments are its spec (bearer header, stdio env); a message from another
  # process can hold anything.
  #
  # `Raxol.Agent.Secret.redact_status(_, _, failure: true)` reduces a reason
  # to one atom; this keeps the nested tags and HTTP statuses the broker's
  # callers and its reconnect logic branch on.

  @doc """
  `reason` with every argument-carrying term removed: nested `{atom, inner}`
  tags are kept (to depth 4), `{tag, status, body}` keeps `{tag, status}`,
  and the innermost reason becomes an atom, an HTTP status or a module;
  anything else becomes `:error`. Collapsing twice gives the same term.
  """
  @spec collapse(term()) :: term()
  def collapse(reason), do: collapse(reason, 4)

  defp collapse(reason, _depth) when is_atom(reason), do: reason
  defp collapse({:http, status}, _depth) when is_integer(status), do: {:http, status}

  # What the next clause leaves of `{tag, status, body}`, kept as it is so a
  # second collapse (a reply that is logged too) changes nothing.
  defp collapse({tag, status}, _depth) when is_atom(tag) and is_integer(status),
    do: {tag, status}

  # `{:token_rejected, 500, body}`: the tag and status, not the body.
  defp collapse({tag, status, _detail}, _depth) when is_atom(tag) and is_integer(status),
    do: {tag, status}

  defp collapse(%{__exception__: true, __struct__: module}, _depth), do: module

  defp collapse({%{__exception__: true, __struct__: module}, stack}, _depth) when is_list(stack),
    do: module

  defp collapse({reason, stack}, _depth) when is_atom(reason) and is_list(stack), do: reason

  defp collapse({tag, inner}, depth) when is_atom(tag) and depth > 0,
    do: {tag, collapse(inner, depth - 1)}

  defp collapse(%{__struct__: module}, _depth), do: module
  defp collapse(_reason, _depth), do: :error

  @doc ~s(A message's leading atom only, as text: `"{:tag, ...}"`, else `"term"`.)
  @spec shape(term()) :: String.t()
  def shape(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) -> "{#{inspect(tag)}, ...}"
      _other -> "{term, ...}"
    end
  end

  def shape(_message), do: "term"
end

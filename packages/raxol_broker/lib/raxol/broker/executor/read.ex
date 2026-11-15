defmodule Raxol.Broker.Executor.Read do
  @moduledoc """
  Read tools on the executor's own session: the context the policy needs
  (`Raxol.Broker.Policy.ContextBuilder`), the account pin, and the order
  and approval lists the kill switch and reconciliation work from.

  Only a tool the session's `Raxol.Broker.Tools.Catalog` classes say is
  `:read` is called; anything else is `{:error, {:tool_refused, tool,
  class}}` and nothing is sent. The answer is read with
  `Raxol.Broker.Response.body/1`.
  """

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Response
  alias Raxol.Broker.Tools.Catalog

  @doc "Call read tool `tool` with `args`; `{:ok, body}` or `{:error, reason}`."
  @spec call(Port.t() | nil, Catalog.session(), String.t(), map(), timeout()) ::
          {:ok, map() | list()} | {:error, term()}
  def call(port, catalog, tool, args, timeout) do
    with :ok <- Catalog.permit(catalog, tool, :read),
         do: Response.body(Port.call(port, tool, args, timeout))
  end

  @max_pages 20

  @doc """
  Every item of a cursored listing: calls `tool` with `args`, then again
  with `"cursor"` set to each page's `next` (see
  `Raxol.Broker.Response.page/2`), at most #{@max_pages} pages. `{:ok,
  items}` only for a complete listing; an unreadable page, a failed call or
  a listing longer than the page limit is `{:error, reason}`, so absence is
  never concluded from part of a list.
  """
  @spec listing(Port.t() | nil, Catalog.session(), String.t(), map(), [String.t()], timeout()) ::
          {:ok, list()} | {:error, term()}
  def listing(port, catalog, tool, args, keys, timeout) do
    with :ok <- Catalog.permit(catalog, tool, :read),
         do: pages(port, tool, args, keys, timeout, @max_pages, [])
  end

  defp pages(_port, tool, _args, _keys, _timeout, 0, _acc), do: {:error, {:too_many_pages, tool}}

  defp pages(port, tool, args, keys, timeout, left, acc) do
    case Response.page(Port.call(port, tool, args, timeout), keys) do
      {:ok, items, nil} ->
        {:ok, Enum.concat(Enum.reverse([items | acc]))}

      {:ok, items, next} ->
        pages(port, tool, Map.put(args, "cursor", next), keys, timeout, left - 1, [items | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end
end

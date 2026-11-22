defmodule Raxol.Web3.Backend.Paging do
  @moduledoc """
  Cursor plumbing shared by the paginating backends.

  A cursor is minted and verified against the scope of the source that served
  the page (`Raxol.Web3.Scope.id/1` of its full base URL), so it is refused
  on another source, including another path or tenant on the same host. See
  `Raxol.Web3.Cursor` for the format.
  """

  alias Raxol.Web3.Cursor

  @doc "Mint the next page's cursor, or `nil` when `params` is not a map (the last page)."
  @spec next_cursor(term(), Raxol.Web3.Scope.t(), Cursor.endpoint()) :: Cursor.t() | nil
  def next_cursor(params, scope, endpoint) when is_map(params) do
    Cursor.encode(params, scope, endpoint)
  end

  def next_cursor(_absent, _scope, _endpoint), do: nil

  @doc """
  The parameters a held cursor carries. No cursor is page one, `{:ok, %{}}`;
  a cursor that fails verification is `{:invalid_cursor, reason}`.
  """
  @spec cursor_params(Cursor.t() | nil, Raxol.Web3.Scope.t(), Cursor.endpoint()) ::
          {:ok, map()} | {:error, {:invalid_cursor, Cursor.reason()}}
  def cursor_params(nil, _scope, _endpoint), do: {:ok, %{}}

  def cursor_params(cursor, scope, endpoint) do
    case Cursor.decode(cursor, scope, endpoint) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, {:invalid_cursor, reason}}
    end
  end

  @doc """
  Refuse a cursor on a read that mints none. Serving page one again for a
  cursor nobody minted is a silent rewind, indistinguishable from a walk that
  ended, so it is `{:invalid_cursor, :wrong_scope}`.
  """
  @spec no_cursor(term()) :: :ok | {:error, {:invalid_cursor, :wrong_scope}}
  def no_cursor(nil), do: :ok
  def no_cursor(_held), do: {:error, {:invalid_cursor, :wrong_scope}}
end

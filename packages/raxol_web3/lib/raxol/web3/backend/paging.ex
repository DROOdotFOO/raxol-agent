defmodule Raxol.Web3.Backend.Paging do
  @moduledoc """
  Origin-bound cursor plumbing shared by the paginating backends.

  A cursor is minted and verified against the origin id of the source that
  served the page, so `origin_id/1` is the one place a backend's base URL
  becomes that id. See `Raxol.Web3.Cursor` for the format.
  """

  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Origin

  @doc "The origin id for a base URL."
  @spec origin_id(String.t() | URI.t()) :: Origin.id()
  def origin_id(url), do: url |> URI.new!() |> Origin.id()

  @doc "Mint the next page's cursor, or `nil` when `params` is not a map (the last page)."
  @spec next_cursor(term(), String.t(), Cursor.endpoint()) :: Cursor.t() | nil
  def next_cursor(params, origin_id, endpoint) when is_map(params) do
    Cursor.encode(params, origin_id, endpoint)
  end

  def next_cursor(_absent, _origin_id, _endpoint), do: nil

  @doc """
  The parameters a held cursor carries. No cursor is page one, `{:ok, %{}}`;
  a cursor that fails verification is `{:invalid_cursor, reason}`.
  """
  @spec cursor_params(Cursor.t() | nil, String.t(), Cursor.endpoint()) ::
          {:ok, map()} | {:error, {:invalid_cursor, Cursor.reason()}}
  def cursor_params(nil, _origin_id, _endpoint), do: {:ok, %{}}

  def cursor_params(cursor, origin_id, endpoint) do
    case Cursor.decode(cursor, origin_id, endpoint) do
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

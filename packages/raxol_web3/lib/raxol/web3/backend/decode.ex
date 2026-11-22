defmodule Raxol.Web3.Backend.Decode do
  @moduledoc """
  Total readers over upstream JSON, shared by the HTTP backends.

  Every value these functions walk belongs to an upstream. `get_in/2` and the
  `[]` access syntax raise on anything that is not a map, so these read a
  wrong-typed value as an absent one instead, and the backend decides whether
  absence is an answer or a `{:decode_failed, _}`.

  The strict, error-returning readers for money and integers live on
  `Raxol.Web3.Backend` (`money/2`, `int/2`); `int/1` here is the lenient one,
  for fields where an unreadable value is reported as `nil`.
  """

  @typedoc "A decoded 2xx body, or the error that stands in for one."
  @type response :: {:ok, map()} | {:error, term()}

  @doc "Walk `path` through nested maps, yielding `nil` at the first non-map."
  @spec dig(term(), [term()]) :: term()
  def dig(value, path), do: Enum.reduce(path, value, fn key, inner -> field(inner, key) end)

  @doc "`Map.get/2` that answers `nil` for a non-map."
  @spec field(term(), term()) :: term()
  def field(map, key) when is_map(map), do: Map.get(map, key)
  def field(_other, _key), do: nil

  @doc "The value if it is a map, otherwise `%{}`."
  @spec object(term()) :: map()
  def object(value) when is_map(value), do: value
  def object(_other), do: %{}

  @doc "The value if it is a list, otherwise `[]`."
  @spec rows_of(term()) :: list()
  def rows_of(value) when is_list(value), do: value
  def rows_of(_other), do: []

  @doc """
  A page's row list. Absent is an empty page; a non-list where the list
  belongs is `{:decode_failed, :page}`, since an empty page would report an
  account as holding nothing.
  """
  @spec page_rows(term()) :: {:ok, list()} | {:error, {:decode_failed, :page}}
  def page_rows(nil), do: {:ok, []}
  def page_rows(rows) when is_list(rows), do: {:ok, rows}
  def page_rows(_other), do: {:error, {:decode_failed, :page}}

  @doc """
  Turn a `Map.fetch/2`-style result into a tagged error.

  `mapper` shapes the error reason, so a backend that reports
  `{:unsupported_chain, ref}` passes `&{:unsupported_chain, &1}` rather than
  keeping its own copy.
  """
  @spec ok_or({:ok, value} | :error, reason, (reason -> term())) ::
          {:ok, value} | {:error, term()}
        when value: term(), reason: term()
  def ok_or(result, reason, mapper \\ &Function.identity/1)
  def ok_or({:ok, _value} = ok, _reason, _mapper), do: ok
  def ok_or(:error, reason, mapper), do: {:error, mapper.(reason)}

  @doc "An integer or a decimal-integer string, otherwise `nil`."
  @spec int(term()) :: integer() | nil
  def int(value) when is_integer(value), do: value

  def int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _invalid -> nil
    end
  end

  def int(_other), do: nil

  @doc "An ISO 8601 timestamp as a `DateTime`, otherwise `nil`."
  @spec iso8601(term()) :: DateTime.t() | nil
  def iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  def iso8601(_other), do: nil

  @doc """
  Decode an HTTP result whose 2xx body must be a JSON object.

  A non-2xx carries only its status onward: an error page is upstream text,
  and ADR-0038 decision 6 keeps upstream text out of an error term.
  """
  @spec json_object({:ok, %{status: integer(), body: binary()}} | {:error, term()}) :: response()
  def json_object({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, :not_an_object}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  def json_object({:ok, %{status: status}}), do: {:error, {:http, status}}
  def json_object({:error, _reason} = error), do: error
end

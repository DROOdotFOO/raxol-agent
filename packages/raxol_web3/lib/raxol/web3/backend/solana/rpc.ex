defmodule Raxol.Web3.Backend.Solana.RPC do
  @moduledoc false
  # Internal to `Raxol.Web3.Backend.Solana`.
  #
  # The JSON-RPC half of `Raxol.Web3.Backend.Solana`: one POST per call, the
  # documented rate-limit seed, and a cache stage that is told which bodies
  # are answers, because a node announces every refusal inside a 200.

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.RPC.ErrorClass

  @typedoc "The fields of a Solana handle this module reads."
  @type state :: %{
          required(:url) => String.t(),
          required(:http_opts) => keyword(),
          required(:cache?) => boolean(),
          optional(atom()) => term()
        }

  # Documented, not measured: the public endpoint's published limit is 100
  # requests per 10 seconds per IP (read 2026-09-14).
  @rate_limit [capacity: 100, refill_per_second: 10.0]

  @content_type {"content-type", "application/json"}

  @overrides %{-32_004 => :not_found}

  @doc "The slot at `commitment`."
  @spec slot(state(), String.t()) :: {:ok, non_neg_integer()} | {:error, Backend.error()}
  def slot(state, commitment) do
    case call(state, "getSlot", [%{"commitment" => commitment}], nil) do
      {:ok, number} when is_integer(number) -> {:ok, number}
      {:ok, _other} -> {:error, {:decode_failed, :slot}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  One JSON-RPC call, with a node's error code collapsed into the closed
  taxonomy. `class` names the cache class, or `nil` for an uncached call.
  """
  @spec call(state(), String.t(), list(), Raxol.Web3.TTL.class() | nil) ::
          {:ok, term()} | {:error, Backend.error()}
  def call(state, method, params, class) do
    case raw(state, method, params, class) do
      {:rpc_error, code} -> {:error, {:upstream_refused, error_class(code)}}
      result -> result
    end
  end

  @doc """
  `call/4` without the collapse: a node error is `{:rpc_error, code}`.
  `get_block/2` needs the code, because -32009 (a skipped slot) is a success.
  """
  @spec raw(state(), String.t(), list(), Raxol.Web3.TTL.class() | nil) ::
          {:ok, term()} | {:rpc_error, integer() | nil} | {:error, Backend.error()}
  def raw(state, method, params, class) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    opts =
      state.http_opts
      |> Keyword.put_new(:rate_limit, @rate_limit)
      # `Backend.put_header/2` rather than a `Keyword.put`: `:http_opts` is
      # documented as forwarded unchanged, and a deployment pointing this
      # handle at its own gated node carries the credential for it in a
      # header there.
      |> Backend.put_header(@content_type)
      |> Cache.opts(state.cache?, {method, params}, class)
      |> classified()

    state.url
    |> HTTP.post(body, opts)
    |> rpc_response()
  end

  # A node announces every refusal inside a 200, so the cache stage cannot
  # tell an answer from a refusal by status and has to be told. This is the
  # chain where it bites hardest: `getBlock` on a slot at the head answers
  # -32004 until the block lands, and the `:block` class would serve that "not
  # available" for the next minute on a node that already has it.
  defp classified(opts) do
    case Keyword.get(opts, :cache) do
      nil -> opts
      spec -> Keyword.put(opts, :cache, Keyword.put(spec, :cacheable, &answered?/1))
    end
  end

  # -32009 is the exception, and it is the same exception `block_result/2`
  # makes: a skipped slot is a permanent fact about this chain rather than a
  # refusal by this source, so it is worth a minute in the table. Every other
  # error code describes the source or the moment.
  defp answered?(%{body: body}) do
    case Jason.decode(body) do
      {:ok, %{"result" => _value}} -> true
      {:ok, %{"error" => %{"code" => -32_009}}} -> true
      _refusal -> false
    end
  end

  defp rpc_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => %{"code" => code}}} when is_integer(code) -> {:rpc_error, code}
      # A code that is not an integer is upstream text, and it does not travel.
      {:ok, %{"error" => %{"code" => _other}}} -> {:rpc_error, nil}
      {:ok, _other} -> {:error, {:decode_failed, :jsonrpc}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  defp rpc_response({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp rpc_response({:error, _reason} = error), do: error

  @doc """
  A node error code's class in `{:upstream_refused, class}`: the shared
  `Raxol.Web3.RPC.ErrorClass` table, plus -32004 ("block not available for slot"),
  which on Solana is an answer about the slot rather than a source failure.
  """
  @spec error_class(term()) :: ErrorClass.class()
  def error_class(code), do: ErrorClass.of_code(code, @overrides)
end

defmodule Raxol.AgentClientProtocol.Connection.Wire do
  @moduledoc false
  # Pure JSON-RPC frame builders and decoders used by the Connection.

  alias Raxol.AgentClientProtocol.{Error, Router}
  alias Raxol.AgentClientProtocol.Rpc.{Message, RequestId, Response}

  @type result :: {:ok, map()} | {:error, Error.t()}

  @spec frame(Message.inner()) :: map()
  def frame(message), do: message |> Message.wrap() |> Message.to_json()

  # A result that fails to encode becomes -32603 instead of raising in the
  # Connection.
  @spec response(RequestId.t(), result()) :: map()
  def response(id, {:ok, result}) when is_map(result) do
    case to_wire(result) do
      {:ok, wire_result} -> frame(Response.result(id, wire_result))
      {:error, _reason} -> frame(Response.error(id, Error.internal_error()))
    end
  end

  def response(id, {:error, %Error{} = err}), do: frame(Response.error(id, err))

  @spec error(RequestId.t(), Error.t(), term()) :: map()
  def error(id, %Error{} = error, data), do: response(id, {:error, Error.with_data(error, data)})

  # Flattens a struct/map to a plain string-keyed map so in-process transports
  # hand the peer a decodable term. A non-JSON-safe value (pid, ref, tuple) is
  # reported instead of raising inside a `handle_call`.
  @spec to_wire(term()) :: {:ok, term()} | {:error, {:encode, Exception.t()}}
  def to_wire(nil), do: {:ok, nil}

  def to_wire(params) do
    case Jason.encode(params) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  @spec decode_result(Response.t(), String.t()) ::
          {:ok, struct() | {:ext, term()}} | {:error, Error.t() | {:result_decode, term()}}
  def decode_result({:error, _id, %Error{} = err}, _method), do: {:error, err}

  def decode_result({:result, _id, raw}, method) do
    case Router.result_marker(method) do
      {:decode, mod} -> decode_with(mod, raw)
      _ext_or_unknown -> {:ok, {:ext, raw}}
    end
  end

  defp decode_with(mod, raw) do
    case mod.from_json(raw) do
      {:ok, struct} -> {:ok, struct}
      {:error, reason} -> {:error, {:result_decode, reason}}
    end
  end

  # Handler return values are untrusted. Table methods must return their result
  # struct; extension methods (no decode marker) may return any map.
  @spec handler_result(term(), String.t()) :: {:ok, result()} | :malformed
  def handler_result({:ok, %_{}} = ok, _method), do: {:ok, ok}
  def handler_result({:error, %Error{}} = err, _method), do: {:ok, err}

  def handler_result({:ok, map} = ok, method) when is_map(map) do
    if match?({:decode, _}, Router.result_marker(method)), do: :malformed, else: {:ok, ok}
  end

  def handler_result(_other, _method), do: :malformed
end

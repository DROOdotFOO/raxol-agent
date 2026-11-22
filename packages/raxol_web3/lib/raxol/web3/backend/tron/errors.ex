defmodule Raxol.Web3.Backend.Tron.Errors do
  @moduledoc """
  Maps what the Tron MCP sources return onto `Raxol.Web3.Backend.error()`.

  Nothing upstream travels: a JSON-RPC error contributes its numeric code and
  never its message, and a refusal announced in prose is classified by shape.
  """

  alias Raxol.Web3.Backend
  alias Raxol.Web3.RPC.ErrorClass

  @doc """
  Decode a tool result's `content[0].text`, which holds a JSON string:
  `Raxol.MCP.Client` decoded the envelope, this decodes the text.
  """
  @spec content_payload(term()) :: {:ok, map()} | {:error, Backend.error()}
  def content_payload([%{"text" => text} | _rest]) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) -> payload_result(payload)
      {:ok, _other} -> {:error, {:decode_failed, :not_an_object}}
      {:error, _reason} -> {:error, {:decode_failed, :mcp_content}}
    end
  end

  def content_payload(_other), do: {:error, {:decode_failed, :mcp_content}}

  @doc """
  A payload whose only key is a string `error` is a refusal inside a
  successful tool result; TronScan announces its pagination ceiling that way.
  The text is prose, so the class is `:unknown` rather than a reading of it.
  """
  @spec payload_result(map()) :: {:ok, map()} | {:error, {:upstream_refused, :unknown}}
  def payload_result(%{"error" => reason} = payload) when is_binary(reason) do
    if map_size(payload) == 1, do: {:error, {:upstream_refused, :unknown}}, else: {:ok, payload}
  end

  def payload_result(payload), do: {:ok, payload}

  @doc "Every reason `Raxol.MCP.Client` produces, mapped onto the closed taxonomy."
  @spec client_error(term()) :: Backend.error()
  def client_error({:http, status}), do: {:http, status}
  def client_error({:redirect_refused, status}), do: {:http, status}
  def client_error({:too_large, limit}), do: {:too_large, limit}
  def client_error({:timeout, stage}), do: {:timeout, stage}
  def client_error(:timeout), do: {:timeout, :deadline}
  def client_error({:transport, reason}), do: {:transport, reason}
  def client_error({:blocked, reason}), do: {:blocked, reason}
  def client_error({:not_ready, _status}), do: {:transport, :not_ready}
  # Retryable, and a source error rather than an answer, so the router fails
  # over to the next candidate instead of returning a saturated queue.
  def client_error(:busy), do: {:transport, :busy}
  def client_error(:session_rejected), do: {:transport, :session_rejected}
  def client_error(:breaker_open), do: {:breaker_open, :unknown}
  def client_error(:dns_failed), do: {:dns_failed, :unknown}

  def client_error(%{"code" => code}) when is_integer(code),
    do: {:upstream_refused, ErrorClass.of_code(code)}

  def client_error(_other), do: {:transport, :unknown}
end

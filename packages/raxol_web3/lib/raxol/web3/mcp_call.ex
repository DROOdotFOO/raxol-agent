defmodule Raxol.Web3.MCPCall do
  @moduledoc """
  One stateless MCP `tools/call`, out through `Raxol.Web3.HTTP`.

  A stateless streamable-HTTP MCP server needs no `initialize`, no
  `notifications/initialized` and no `mcp-session-id`: one POST per call. This
  module knows nothing about any chain; it takes an endpoint, a tool name, an
  argument map and `Raxol.Web3.HTTP` options.

  ## Return shapes

  `result.content[0].text` holds a JSON string, so there are two decodes. The
  result is:

    * `{:ok, payload}` -- the tool answered.
    * `{:tool_error, payload}` -- the tool set `isError`; this is its structured
      body (e.g. SQD's `error.code` `"unknown_network"` vs `"invalid_request"`).
    * `{:error, reason}` -- transport, status, framing or envelope failure, from
      `Raxol.Web3.Backend`'s closed taxonomy.

  **A caller must map `{:tool_error, payload}` onto a closed error term and drop
  the payload**: upstream text never travels in an error tuple (ADR-0038
  decision 6). An `isError` body that is not a JSON object is
  `{:upstream_refused, :unknown}`.

  The payload is returned whole, including model-facing prose and fields the
  upstream marks untrusted; the calling backend takes only the fields it names.
  `result.structuredContent` is ignored.

  ## Framing

  The body is tried as `application/json` first, then unframed as
  `text/event-stream` via `Raxol.MCP.Client.SSE.payloads/1`, rather than
  trusting `content-type`.
  """

  alias Raxol.MCP.Client.SSE
  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.RPC.ErrorClass

  # Defaults, merged per name rather than assigned over the caller's list. An
  # account-gated server needs an `authorization` header, and a module that
  # replaced the list would make a credential structurally impossible to send.
  # `accept` carries both types because the spec lets a streamable-HTTP server
  # answer a POST either way and a client that accepts only one is at the
  # server's mercy; put_new semantics mean a caller cannot drop it by supplying
  # unrelated headers, only by setting it deliberately.
  @default_headers [
    {"content-type", "application/json"},
    {"accept", "application/json, text/event-stream"}
  ]

  @type result :: {:ok, map()} | {:tool_error, map()} | {:error, Backend.error()}

  @doc """
  Call one tool and return its decoded payload.

  `opts` is forwarded to `Raxol.Web3.HTTP` unchanged except for `:headers`, so
  the caller owns the cache class, the rate-limit seed and the breaker
  settings: this module has no opinion about any of them, because it does not
  know whose budget it is spending. `:headers` is merged with the two defaults
  above, so a caller's `authorization` survives and the defaults appear only
  where the caller did not set them. `user-agent` is not policed here;
  `Raxol.Web3.HTTP` drops a supplied one and sets its own.
  """
  @spec call(String.t(), String.t(), map(), keyword()) :: result()
  def call(endpoint, tool, arguments, opts \\ [])
      when is_binary(endpoint) and is_binary(tool) and is_map(arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => arguments}
      })

    endpoint
    |> HTTP.post(body, opts |> Keyword.put(:headers, headers(opts)) |> classified())
    |> decode()
  end

  # An MCP tool server announces a refusal inside a 200 in three different
  # shapes -- a JSON-RPC `error` on the envelope, `isError: true` on the
  # result, and an `error` object carrying a `code` in the payload itself --
  # so the cache stage cannot tell an answer from a refusal by status and has
  # to be told. The measured cost of not telling it: SQD's
  # `portal_list_networks` is cached under `:catalog` for an hour, so one
  # transient tool error resolved every read on that source to a refusal for
  # the rest of the hour while the source was already answering again.
  defp classified(opts) do
    case Keyword.get(opts, :cache) do
      nil -> opts
      spec -> Keyword.put(opts, :cache, Keyword.put(spec, :cacheable, &answered?/1))
    end
  end

  # `decode/1` itself, rather than a second reading of the same body: the two
  # would have to agree about the refusal shapes forever, and the only way to
  # guarantee that is to have one of them.
  #
  # The third shape is the one `decode/1` cannot own, because it is not a
  # refusal at the MCP level at all: the server answered, `isError` is absent,
  # and what came back is a well-formed payload whose CONTENT says no.
  # `Raxol.Web3.Backend.SQD.refusal/2` reads exactly that payload and
  # turns `unknown_network` into `{:unsupported_chain, _}`, so caching it puts
  # the same refusal in front of every read of that class for the whole TTL,
  # which is the bug this predicate exists to remove. Returning the payload to
  # the caller unchanged and merely declining to STORE it is the conservative
  # half: a genuine payload that happens to carry an `error` code costs one
  # re-fetch, where a cached refusal costs an hour of wrong answers.
  defp answered?(response) do
    case decode({:ok, response}) do
      {:ok, payload} -> not payload_refusal?(payload)
      _refused -> false
    end
  end

  defp payload_refusal?(%{"error" => %{"code" => _code}}), do: true
  defp payload_refusal?(_payload), do: false

  defp headers(opts) do
    Enum.reduce(@default_headers, Keyword.get(opts, :headers, []), fn {name, value}, headers ->
      put_new_header(headers, name, value)
    end)
  end

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {supplied, _value} -> String.downcase(supplied) == name end),
      do: headers,
      else: [{name, value} | headers]
  end

  defp decode({:ok, %{status: status, body: body}}) when status in 200..299 do
    with {:ok, envelope} <- envelope(body),
         {:ok, result} <- result(envelope) do
      content(result)
    end
  end

  defp decode({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp decode({:error, _reason} = error), do: error

  defp envelope(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      _not_json ->
        case SSE.payloads(body) do
          {[payload | _rest], _tail} -> json_object(payload, :sse)
          {[], _tail} -> {:error, {:decode_failed, :sse}}
        end
    end
  end

  defp result(%{"result" => result}) when is_map(result), do: {:ok, result}
  defp result(%{"error" => error}), do: {:error, {:upstream_refused, ErrorClass.of_error(error)}}
  defp result(_other), do: {:error, {:decode_failed, :jsonrpc}}

  defp content(%{"content" => [%{"text" => text} | _rest]} = result) when is_binary(text) do
    case json_object(text, :mcp_content) do
      {:ok, payload} -> tag(result, payload)
      {:error, _reason} = error -> announced(result, error)
    end
  end

  defp content(result), do: announced(result, {:error, {:decode_failed, :mcp_content}})

  defp tag(%{"isError" => true}, payload), do: {:tool_error, payload}
  defp tag(_result, payload), do: {:ok, payload}

  defp announced(%{"isError" => true}, _error), do: {:error, {:upstream_refused, :unknown}}
  defp announced(_result, error), do: error

  defp json_object(text, tag) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, tag}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end
end

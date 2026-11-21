defmodule Raxol.Agent.Backend.HTTP do
  @moduledoc """
  HTTP-based AI backend using Req.

  Supports Claude (Anthropic), GPT (OpenAI-compatible), Ollama, and Kimi APIs.
  The provider is auto-detected from the base URL or can be set explicitly.

  ## Configuration

      opts = [
        api_key: "sk-...",
        base_url: "https://api.anthropic.com",
        model: "claude-sonnet-4-20250514",
        provider: :anthropic,  # or :openai, :ollama, :kimi (auto-detected if omitted)
        timeout: 30_000
      ]

  ## Req Plugins

  Pass `:req_plugins` to attach Req response steps (e.g., auto-pay for HTTP 402):

      opts = [
        api_key: "sk-...",
        req_plugins: [
          fn req ->
            Raxol.Payments.Req.AutoPay.attach(req,
              wallet: MyWallet,
              policy: Raxol.Payments.SpendingPolicy.dev()
            )
          end
        ]
      ]

  Each plugin is a function `(Req.Request.t() -> Req.Request.t())` applied
  before the request is sent. This keeps Backend.HTTP agnostic to payment
  details while letting callers wire in transparent 402 handling.

  ## Streaming limits

  `stream/2` ends with `{:error, message}` when the whole response passes
  `:max_stream_bytes` (default 128 MiB of wire bytes, every redirect hop
  included, counted as it arrives whether or not the stream is being read;
  a token of an OpenAI-style stream costs a few hundred bytes of JSON), when
  its unframed remainder passes
  `:max_sse_buffer_bytes` (default 1 MiB), when streamed tool-call arguments
  together pass `:max_tool_call_bytes` (default 1 MiB), or when it streams
  more than `:max_tool_calls` (default 128) calls. Each is an option to
  `stream/2`.

  Only a 2xx response's body is streamed: a redirect's or an error's body
  is counted but never surfaces as model output.

  The stream's events are delivered to the process that called `stream/2`,
  so that process must read it: enumerating it anywhere else raises
  `ArgumentError` and stops the request.
  """

  @behaviour Raxol.Agent.AIBackend

  alias Raxol.Agent.Backend.Anthropic.Wire
  alias Raxol.Agent.Backend.HTTP.Choice
  alias Raxol.Agent.Backend.HTTP.Models
  alias Raxol.Agent.Backend.HTTP.SSE
  alias Raxol.Agent.Backend.HTTP.ToolCalls

  @default_timeout Raxol.Core.Defaults.health_check_interval_ms()
  # Room for a reasoning model's hidden reasoning plus its answer; a lower
  # cap ends such turns with `finish_reason: length` and no answer.
  @default_max_tokens 4_096
  @default_ollama_port "11434"
  @stream_idle_ms 60_000
  # Streaming input limits. A provider (or anything in the path to one) that
  # never sends an event boundary, or streams tool-call fragments without
  # end, would otherwise grow the caller's memory without bound.
  @max_sse_buffer_bytes 1_048_576
  @max_stream_bytes 134_217_728
  @max_tool_call_bytes 1_048_576
  @max_tool_calls 128

  # An unparseable body or an empty length-truncated turn is an error, never
  # assistant prose.
  @impl true
  def complete(messages, opts \\ []) do
    provider = detect_provider(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    plugins = Keyword.get(opts, :req_plugins, [])
    {url, headers, body} = build_request(provider, messages, opts)

    with {:ok, response_body} <- do_request(url, headers, body, timeout, plugins) do
      parse_response(provider, response_body)
    end
  end

  # Precedence: explicit `:max_tokens` > `AI_MAX_TOKENS` > `@default_max_tokens`.
  defp default_max_tokens do
    with raw when is_binary(raw) <- System.get_env("AI_MAX_TOKENS"),
         {n, _} when n > 0 <- Integer.parse(String.trim(raw)) do
      n
    else
      _ -> @default_max_tokens
    end
  end

  @impl true
  def available?, do: Code.ensure_loaded?(Req)

  @doc """
  Cheap credential check via the provider's model-list endpoint, which costs
  no tokens. Returns:

    * `:valid`                    — a 2xx (authorized),
    * `{:rejected, status}`       — 401/403 (bad key),
    * `{:reachable_error, status}`— reachable but another status,
    * `:unreachable`              — transport failure,
    * `:unsupported`             — no known model-list endpoint for this
      provider (the caller should fall back to a completion ping).
  """
  @spec check_auth(keyword()) ::
          :valid
          | {:rejected, non_neg_integer()}
          | {:reachable_error, non_neg_integer()}
          | :unreachable
          | :unsupported
  def check_auth(opts) do
    if available?(),
      do: opts |> auth_check_request() |> Models.check(timeout(opts)),
      else: :unsupported
  end

  @doc false
  # The `{url, headers}` `check_auth/1` would call, or `:unsupported`.
  @spec auth_check_request(keyword()) :: Models.request()
  def auth_check_request(opts), do: opts |> detect_provider() |> Models.request(opts)

  @doc """
  List a provider's model ids via the endpoint `check_auth/1` uses.

  Returns `{:ok, ids}`, `{:error, reason}` (transport failure or non-2xx), or
  `:unsupported` (no known model-list endpoint; the caller should fall back
  to typing a model name).
  """
  @spec list_models(keyword()) :: {:ok, [String.t()]} | {:error, term()} | :unsupported
  def list_models(opts) do
    if available?() do
      provider = detect_provider(opts)
      provider |> Models.request(opts) |> Models.list(provider, timeout(opts))
    else
      :unsupported
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  @impl true
  def name, do: "HTTP Backend"

  @impl true
  def capabilities, do: [:completion, :streaming, :tool_use]

  @doc """
  Stream a completion. Besides the configuration options, takes
  `:max_stream_bytes`, `:max_sse_buffer_bytes`, `:max_tool_call_bytes` and
  `:max_tool_calls` (see "Streaming limits"). The stream must be read by the
  calling process.
  """
  @impl true
  def stream(messages, opts \\ []) do
    if available?() do
      provider = detect_provider(opts)
      plugins = Keyword.get(opts, :req_plugins, [])
      {url, headers, body} = build_request(provider, messages, opts)
      body = Map.put(body, :stream, true)
      caller = self()
      ref = make_ref()
      limits = stream_limits(opts)

      task_pid =
        spawn_link(fn ->
          stream_request(url, headers, body, timeout(opts), {caller, ref, limits}, plugins)
        end)

      stream =
        Stream.resource(
          fn ->
            unless self() == caller do
              send(task_pid, {:sse_stop, ref})

              raise ArgumentError,
                    "an HTTP backend stream must be read by the process that called stream/2"
            end

            %{
              ref: ref,
              task_pid: task_pid,
              buffer: "",
              provider: provider,
              content: "",
              usage: %{},
              tool_calls_acc: %{},
              limits: limits
            }
          end,
          &stream_next/1,
          &stop_request/1
        )

      {:ok, stream}
    else
      {:error, :req_not_available}
    end
  end

  # `:sse_done` follows a response or a rescued raise, never an exit, so a
  # transport exit is not collected as a finished stream.
  defp stream_request(url, headers, body, timeout, {caller, ref, _limits} = target, plugins) do
    post_stream(url, headers, body, timeout, target, plugins)
    send(caller, {:sse_done, ref})
  end

  defp post_stream(url, headers, body, timeout, {caller, ref, limits}, plugins) do
    req =
      Req.new(
        url: url,
        json: body,
        headers: headers,
        receive_timeout: timeout,
        into: &forward(&1, &2, caller, ref, limits.stream_bytes)
      )
      |> apply_plugins(plugins)

    case Req.post(req) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> send(caller, {:sse_error, ref, "HTTP #{status}"})
      {:error, reason} -> send(caller, {:sse_error, ref, inspect(reason)})
    end
  rescue
    e -> send(caller, {:sse_error, ref, Exception.message(e)})
  end

  # The total is counted here, in the request process (which exists for this
  # one request, so its dictionary holds the count across redirect hops and
  # retries), so the cap holds while nobody reads the stream: the caller's
  # mailbox never holds more than it. Only a 2xx body is forwarded. A
  # `:sse_stop` (a reader that is not the owner) ends the request.
  defp forward({:data, data}, {req, resp}, caller, ref, max_bytes) do
    total = Process.get({:raxol_stream_bytes, ref}, 0) + byte_size(data)
    Process.put({:raxol_stream_bytes, ref}, total)

    receive do
      {:sse_stop, ^ref} -> {:halt, {req, resp}}
    after
      0 ->
        cond do
          total > max_bytes ->
            send(caller, {:sse_error, ref, "streamed response exceeded #{max_bytes} bytes"})
            {:halt, {req, resp}}

          resp.status in 200..299 ->
            send(caller, {:sse_data, ref, data})
            {:cont, {req, resp}}

          true ->
            {:cont, {req, resp}}
        end
    end
  end

  defp stream_next(%{buffer: :halt} = state), do: {:halt, state}

  defp stream_next(%{ref: ref} = state) do
    receive do
      {:sse_data, ^ref, data} ->
        {events, buffer} = parse(state, data)
        state = fold_events(%{state | buffer: buffer}, events)

        case check_limits(state) do
          :ok ->
            {stream_events(events), state}

          {:error, error} ->
            {stream_events(events) ++ [{:error, error}], %{state | buffer: :halt}}
        end

      {:sse_error, ^ref, error} ->
        {[{:error, error}], %{state | buffer: :halt}}

      {:sse_done, ^ref} ->
        done = %{
          content: state.content,
          usage: state.usage,
          tool_calls: ToolCalls.finalize(state.tool_calls_acc),
          metadata: %{backend: :http, provider: state.provider, streamed: true}
        }

        {[{:done, done}], %{state | buffer: :halt}}
    after
      @stream_idle_ms -> {:halt, state}
    end
  end

  # Re-parsing the whole buffer for every chunk is quadratic in small chunks,
  # so a chunk that cannot complete an event is only appended.
  defp parse(%{buffer: buffer, provider: provider}, data) do
    if SSE.boundary?(buffer, data, provider),
      do: SSE.parse(buffer <> data, provider),
      else: {[], buffer <> data}
  end

  # `:normal` would not stop the linked request process, which then keeps
  # reading the response into the owner's mailbox. The owner (the only
  # process the start function lets read the stream) unlinks first so the
  # kill does not come back to it, waits for the process to be gone, then
  # drops what it sent.
  defp stop_request(%{task_pid: pid, ref: ref}) do
    monitor = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> Process.demonitor(monitor, [:flush])
    end

    flush_request(ref)
  end

  defp flush_request(ref) do
    receive do
      {:sse_data, ^ref, _} -> flush_request(ref)
      {:sse_error, ^ref, _} -> flush_request(ref)
      {:sse_done, ^ref} -> flush_request(ref)
    after
      0 -> :ok
    end
  end

  defp stream_limits(opts) do
    %{
      stream_bytes: Keyword.get(opts, :max_stream_bytes, @max_stream_bytes),
      buffer_bytes: Keyword.get(opts, :max_sse_buffer_bytes, @max_sse_buffer_bytes),
      tool_call_bytes: Keyword.get(opts, :max_tool_call_bytes, @max_tool_call_bytes),
      tool_calls: Keyword.get(opts, :max_tool_calls, @max_tool_calls)
    }
  end

  defp check_limits(%{buffer: buffer, limits: limits} = state) do
    if byte_size(buffer) > limits.buffer_bytes do
      {:error,
       "streamed response exceeded #{limits.buffer_bytes} bytes without an event boundary"}
    else
      ToolCalls.check_size(state.tool_calls_acc, limits.tool_call_bytes, limits.tool_calls)
    end
  end

  # In arrival order: text is the answer, reasoning and markers ride their
  # own channels.
  defp stream_events(events) do
    Enum.flat_map(events, fn
      {:text_delta, text} -> [{:chunk, text}]
      {:reasoning_delta, text} -> [{:reasoning, text}]
      {:marker, text} -> [{:marker, text}]
      _ -> []
    end)
  end

  # Only text accumulates into `content`; the first usage event of a chunk
  # wins (a trailing `[DONE]` carries an empty one).
  defp fold_events(state, events) do
    text = for {:text_delta, t} <- events, into: "", do: t

    usage =
      case Enum.find(events, &match?({:usage, _}, &1)) do
        {:usage, usage} -> usage
        nil -> state.usage
      end

    max_calls = state.limits.tool_calls

    # Merging stops once past the call limit, which `check_limits/1` then
    # reports, so one large chunk costs at most that many calls of work.
    acc =
      for {:tool_call_delta, frags} <- events,
          reduce: state.tool_calls_acc,
          do: (acc -> ToolCalls.merge(acc, frags, max_calls))

    %{state | content: state.content <> text, usage: usage, tool_calls_acc: acc}
  end

  # A keyless OpenAI-compatible endpoint (LLM7) resolves to `:openai` like
  # api.openai.com, so an absent key sends no auth header and a host that
  # needs one answers 401.
  defp bearer_header(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> [{"authorization", "Bearer #{key}"}]
      _absent -> []
    end
  end

  defp build_request(:anthropic, messages, opts),
    do:
      Wire.build_request(messages, Keyword.put_new_lazy(opts, :max_tokens, &default_max_tokens/0))

  defp build_request(:openai, messages, opts) do
    {url, headers, body} = chat_request(messages, opts, "https://api.openai.com", "gpt-4o")

    body =
      case Keyword.get(opts, :tools) do
        tools when is_list(tools) and tools != [] -> Map.put(body, :tools, tools)
        _none -> body
      end

    {url, headers, body}
  end

  defp build_request(:kimi, messages, opts),
    do: chat_request(messages, opts, "https://api.moonshot.ai", "kimi-k2.5")

  defp build_request(:ollama, messages, opts) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:#{@default_ollama_port}")

    body = %{
      model: Keyword.get(opts, :model, "llama3"),
      messages: Enum.map(messages, &format_message/1),
      stream: false
    }

    {"#{base_url}/api/chat", [{"content-type", "application/json"}], body}
  end

  # Extra headers (e.g. OpenRouter's HTTP-Referer, X-OpenRouter-Title) follow
  # the provider's own.
  defp chat_request(messages, opts, default_base, default_model) do
    base_url = Keyword.get(opts, :base_url, default_base)

    headers =
      bearer_header(opts) ++
        [{"content-type", "application/json"}] ++ Keyword.get(opts, :extra_headers, [])

    body = %{
      model: Keyword.get(opts, :model, default_model),
      messages: Enum.map(messages, &format_message/1),
      max_tokens: Keyword.get(opts, :max_tokens, default_max_tokens())
    }

    {"#{base_url}/v1/chat/completions", headers, body}
  end

  defp parse_response(:anthropic, body), do: Wire.parse_response(body, :http)

  defp parse_response(
         :openai,
         %{"choices" => [%{"message" => %{"tool_calls" => tool_calls}} = choice | _]} = body
       )
       when is_list(tool_calls) and tool_calls != [] do
    msg = Choice.message(choice)

    %{
      content: Choice.text(msg),
      tool_calls: ToolCalls.from_openai(tool_calls),
      usage: Map.get(body, "usage", %{}),
      metadata: %{backend: :http, provider: :openai, model: Map.get(body, "model")}
    }
    |> put_reasoning(Choice.reasoning(msg))
    |> then(&{:ok, &1})
  end

  # Standard OpenAI, LongCat's full-message shape and the reasoning channel.
  # A length-truncated turn with an empty answer is an error.
  defp parse_response(:openai, %{"choices" => [choice | _]} = body) when is_map(choice) do
    msg = Choice.message(choice)
    content = Choice.text(msg)
    finish = Choice.finish_reason(choice)

    if finish == "length" and String.trim(content) == "" do
      {:error, Choice.truncation_marker(body)}
    else
      %{
        content: content,
        usage: Map.get(body, "usage", %{}),
        metadata: openai_metadata(body, finish)
      }
      |> put_reasoning(Choice.reasoning(msg))
      |> then(&{:ok, &1})
    end
  end

  defp parse_response(:kimi, body), do: parse_response(:openai, body)

  defp parse_response(:ollama, %{"message" => %{"content" => text}} = body) do
    {:ok,
     %{
       content: text,
       usage: %{},
       metadata: %{
         backend: :http,
         provider: :ollama,
         model: Map.get(body, "model"),
         eval_duration: Map.get(body, "eval_duration")
       }
     }}
  end

  # The marker names top-level keys only, never values, which may hold
  # secrets.
  defp parse_response(provider, body), do: {:error, Wire.unparseable_marker(provider, body)}

  # A truncated turn that kept some answer stays `{:ok, _}` and carries the
  # marker in metadata, the only channel `complete/2` has beside the answer.
  defp openai_metadata(body, finish) do
    meta = %{backend: :http, provider: :openai, model: Map.get(body, "model")}

    case finish do
      "length" ->
        Map.merge(meta, %{
          finish_reason: :length,
          truncated: true,
          marker: Choice.truncation_marker(body)
        })

      nil ->
        meta

      other ->
        Map.put(meta, :finish_reason, other)
    end
  end

  defp put_reasoning(response, nil), do: response
  defp put_reasoning(response, reasoning), do: Map.put(response, :reasoning, reasoning)

  defp do_request(url, headers, body, timeout, plugins) do
    if available?() do
      req =
        [url: url, json: body, headers: headers, receive_timeout: timeout]
        |> Req.new()
        |> apply_plugins(plugins)

      case Req.post(req) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
        {:ok, %{status: status, body: resp_body}} -> {:error, {:http_error, status, resp_body}}
        {:error, reason} -> {:error, {:request_failed, reason}}
      end
    else
      {:error, :req_not_available}
    end
  end

  defp apply_plugins(req, plugins),
    do: Enum.reduce(plugins, req, fn plugin, acc -> plugin.(acc) end)

  defp detect_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> provider_from_url(Keyword.get(opts, :base_url, ""))
      provider -> provider
    end
  end

  defp provider_from_url(base_url) do
    cond do
      String.contains?(base_url, "anthropic") -> :anthropic
      String.contains?(base_url, ["ollama", @default_ollama_port]) -> :ollama
      String.contains?(base_url, "moonshot") -> :kimi
      true -> :openai
    end
  end

  defp format_message(%{role: role, content: content}),
    do: %{role: to_string(role), content: content}
end

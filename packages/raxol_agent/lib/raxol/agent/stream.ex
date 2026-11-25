defmodule Raxol.Agent.Stream do
  require Logger

  @moduledoc """
  Stream-first API for agent sessions.

  Wraps agent interactions as lazy Elixir Streams with natural backpressure.
  Each element is a typed event tuple. Compose with standard `Stream`/`Enum`
  functions.

  ## Quick Start

      # Stream text deltas from a prompt
      Raxol.Agent.Stream.run("Analyze mix.exs", opts)
      |> Raxol.Agent.Stream.text_deltas()
      |> Enum.each(&IO.write/1)

      {:ok, result} =
        Raxol.Agent.Stream.react("Count lines in mix.exs", opts)
        |> Raxol.Agent.Stream.collect()

  ## Event Types

  - `{:text_delta, text}` -- streaming text chunk from LLM
  - `{:reasoning, text}` -- streaming thinking chunk, distinct from answer text
  - `{:tool_use, %{name, arguments, id}}` -- LLM requesting a tool call
  - `{:tool_result, %{name, result, id}}` -- result from executing a tool;
    `id` is the `:tool_use` id it answers
  - `{:turn_complete, %{content, usage, iteration}}` -- end of one ReAct turn
  - `{:done, %{content, tool_results, usage}}` -- final answer (from `react/2`,
    also `messages`: the conversation the loop built, tool exchanges included)
  - `{:error, reason}` -- error during execution

  ## Options

  Common options for `run/2` and `react/2`:

  - `:executor` -- `Raxol.Agent.ExecutorConfig` selecting backend + model + auth
    (takes precedence over `:backend`)
  - `:backend` -- AIBackend module; ignored when `:executor` is given, even
    when no backend can serve that executor
  - `:auto_provider` -- when `true` and no `:executor` is given, resolve one from
    the environment via `Raxol.Agent.Backend.Resolver` (op-ref ->
    provider-env -> `AI_API_KEY`). An optional `:provider` pins a specific
    one. When nothing resolves, `:backend` is used.
  - `:backend_opts` -- keyword list passed to backend (api_key, model, etc.);
    merged over the executor's resolved opts
  - `:model` -- per-request model override (wins over `:executor`/`:backend_opts`)
  - `:system_prompt` -- system message (binary) prepended to every entry form,
    unless the messages already carry one (which wins; never duplicated)
  - `:messages` -- pre-built message list (overrides prompt)
  - `:stream` -- whether to use streaming backend (default: `true`)

  Additional options for `react/2`:

  - `:actions` -- list of Action modules available as tools
  - `:context` -- map handed to every tool call (default: `%{}`)
  - `:max_iterations` -- loop guard (default: 10)

  With neither an executor nor a `:backend`, the stream is the single event
  `{:error, :no_backend}`; an executor no backend can serve yields
  `{:error, {:backend_unavailable, reason}}`. Neither falls back to a mock. A
  wrong-shaped `:executor` or `:backend` yields `{:error, {:invalid_executor, _}}`
  or `{:error, {:invalid_backend, _}}`.
  """

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.AIBackend
  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Backend.Selector
  alias Raxol.Agent.ExecutorConfig

  @type event ::
          {:text_delta, String.t()}
          | {:reasoning, String.t()}
          | {:tool_use, tool_use()}
          | {:tool_result, tool_result()}
          | {:turn_complete, turn_info()}
          | {:done, done_info()}
          | {:error, term()}

  @type tool_use :: %{name: String.t(), arguments: map(), id: String.t() | nil}
  @type tool_result :: %{
          required(:name) => String.t(),
          required(:result) => map() | {:error, term()},
          optional(:id) => String.t() | nil
        }
  @type turn_info :: %{
          content: String.t(),
          usage: map(),
          model: String.t() | nil,
          iteration: non_neg_integer()
        }
  @type done_info :: %{
          required(:content) => String.t(),
          required(:tool_results) => [tool_result()],
          required(:usage) => map(),
          required(:model) => String.t() | nil,
          # Only the tool loop (`react/2`) reports this: the full conversation
          # it built, for a consumer that has to resume the turn later.
          optional(:messages) => [map()]
        }

  @default_max_iterations 10
  @react_timeout_ms 120_000

  # Config map passed through the react loop to avoid 9-arity functions.
  # Shape: %{backend: module, opts: keyword, actions: [module],
  #          context: map, max_iterations: pos_integer, caller: pid, ref: reference}

  @doc """
  Stream a single LLM completion.

  Returns a lazy `Stream` of events. If the backend supports streaming,
  you get `{:text_delta, chunk}` events followed by `{:done, result}`.
  Otherwise falls back to a single `{:done, result}`.

  ## Examples

      Raxol.Agent.Stream.run("Hello", backend: Backend.Mock, backend_opts: [response: "Hi"])
      |> Enum.to_list()
      #=> [{:text_delta, "Hi"}, {:done, %{content: "Hi", ...}}]
  """
  @spec run(String.t() | [map()], keyword()) :: Enumerable.t()
  def run(prompt_or_messages, opts \\ []) do
    messages = build_messages(prompt_or_messages, opts)

    case resolve_backend(opts) do
      {:ok, backend, backend_opts} -> do_completion(backend, messages, backend_opts, opts)
      {:error, reason} -> [{:error, reason}]
    end
  end

  defp do_completion(backend, messages, backend_opts, opts) do
    use_streaming = Keyword.get(opts, :stream, true)

    if use_streaming and function_exported?(backend, :stream, 2) do
      stream_completion(backend, messages, backend_opts)
    else
      sync_completion(backend, messages, backend_opts)
    end
  end

  @doc """
  Stream a ReAct reasoning loop with tool use.

  The LLM sees available tools (from `:actions`) and can call them.
  Each iteration emits tool_use/tool_result events. Continues until
  the LLM produces a final text answer or `:max_iterations` is reached.

  ## Examples

      Raxol.Agent.Stream.react("Analyze mix.exs", [
        backend: Backend.Mock,
        backend_opts: [response: "The file looks good."],
        actions: [MyAction],
        max_iterations: 5
      ])
      |> Enum.to_list()
  """
  @spec react(String.t() | [map()], keyword()) :: Enumerable.t()
  def react(prompt_or_messages, opts \\ []) do
    messages = build_messages(prompt_or_messages, opts)

    case resolve_backend(opts) do
      {:ok, backend, backend_opts} ->
        if AIBackend.handles_tools_internally?(backend),
          do: native_react(messages, backend, backend_opts, opts),
          else: framework_react(messages, backend, backend_opts, opts)

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  @doc """
  Whether the backend resolved from `opts` runs its own tool loop.

  A backend whose `handles_tools_internally?/0` returns true executes tools
  itself, where the framework cannot thread run context -- `:tool_authorizer`,
  `:tool_call_hooks`, and app flags such as the cron `:in_cron` recursion
  guard -- into tool execution. No backend in the catalog does. A caller that
  exposes a context-guarded tool uses this to fail closed: withhold the tool
  on that path rather than hand over capability the guard cannot police.
  Resolution mirrors `react/2` (executor / auto_provider / `:backend`), so the
  answer matches the backend the turn will actually use.
  """
  @spec native_tool_loop?(keyword()) :: boolean()
  def native_tool_loop?(opts) do
    case resolve_backend(opts) do
      {:ok, backend, _backend_opts} -> AIBackend.handles_tools_internally?(backend)
      {:error, _reason} -> false
    end
  end

  # A backend that owns its tool loop runs the tools itself, so the framework
  # just streams its output.
  defp native_react(messages, backend, backend_opts, opts) do
    do_completion(backend, messages, backend_opts, opts)
  end

  defp framework_react(messages, backend, backend_opts, opts) do
    actions = Keyword.get(opts, :actions, [])
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    context = Keyword.get(opts, :context, %{})

    tools = ToolConverter.to_tool_definitions(actions)
    tool_opts = Keyword.merge(backend_opts, tools: tools)

    caller = self()
    ref = make_ref()

    config = %{
      backend: backend,
      opts: tool_opts,
      actions: actions,
      context: context,
      max_iterations: max_iterations,
      caller: caller,
      ref: ref
    }

    pid =
      spawn_link(fn ->
        react_loop(messages, 0, config)
        send(caller, {:react_done, ref})
      end)

    Stream.resource(
      fn -> %{ref: ref, pid: pid, done: false} end,
      &receive_react_event/1,
      fn %{pid: p} ->
        if Process.alive?(p), do: Process.exit(p, :normal)
      end
    )
  end

  @doc "Filter stream to only text delta events, unwrapping the text."
  @spec text_deltas(Enumerable.t()) :: Enumerable.t()
  def text_deltas(stream) do
    Stream.flat_map(stream, fn
      {:text_delta, text} -> [text]
      _ -> []
    end)
  end

  @doc "Filter stream to only tool use events."
  @spec tool_uses(Enumerable.t()) :: Enumerable.t()
  def tool_uses(stream) do
    Stream.filter(stream, &match?({:tool_use, _}, &1))
  end

  @doc "Filter stream to only tool result events."
  @spec tool_results(Enumerable.t()) :: Enumerable.t()
  def tool_results(stream) do
    Stream.filter(stream, &match?({:tool_result, _}, &1))
  end

  @doc """
  Collect all events and return the final content.

  Drains the stream and returns `{:ok, done_info}` or `{:error, reason}`.
  """
  @spec collect(Enumerable.t()) :: {:ok, done_info()} | {:error, term()}
  def collect(stream) do
    result =
      Enum.reduce(stream, nil, fn
        {:done, info}, _acc -> {:ok, info}
        {:error, reason}, _acc -> {:error, reason}
        _event, acc -> acc
      end)

    result || {:error, :no_result}
  end

  @doc """
  Collect text from a stream into a single string.

  Joins all text deltas. If no text deltas were emitted, falls back
  to the final content from the `:done` event.
  """
  @spec collect_text(Enumerable.t()) :: String.t()
  def collect_text(stream) do
    {text, fallback} =
      Enum.reduce(stream, {"", nil}, fn
        {:text_delta, chunk}, {acc, fb} -> {acc <> chunk, fb}
        {:done, %{content: c}}, {acc, _fb} -> {acc, c}
        _, acc -> acc
      end)

    case text do
      "" -> fallback || ""
      _ -> text
    end
  end

  defp stream_completion(backend, messages, backend_opts) do
    case backend.stream(messages, backend_opts) do
      {:ok, inner_stream} ->
        normalize_backend_stream(inner_stream)

      {:error, reason} ->
        error_stream(reason)
    end
  end

  defp normalize_backend_stream(inner_stream) do
    Stream.transform(inner_stream, :running, fn
      {:chunk, text}, :running ->
        {[{:text_delta, text}], :running}

      # Reasoning/thinking tokens the backend surfaced (Anthropic thinking
      # blocks, OpenAI reasoning). Forwarded as a distinct event so the
      # contract can give reasoning its own durable item lifecycle rather
      # than folding it into the answer text — see `StreamPump.pump/3`.
      {:reasoning, text}, :running ->
        {[{:reasoning, text}], :running}

      # An honest wire-boundary marker (unparseable chunk / length
      # truncation) surfaced by `Backend.HTTP`. Non-fatal: forwarded without
      # halting the turn, so a single bad chunk never kills the stream.
      {:marker, text}, :running ->
        {[{:marker, text}], :running}

      {:done, response}, :running ->
        # `run/2` is the single-completion path -- there is no tool-execution
        # loop downstream of this stream (that is `react/2`). `Backend.HTTP`
        # accumulates streamed `tool_calls` onto the done response even here
        # (`finalize_tool_calls/1`); silently dropping them would strand a
        # model's claimed tool call with zero receipt while the turn still
        # reports a clean done -- a green-wash. Seal an honest
        # `:tool_unexecuted` marker per call instead: the vocabulary already
        # exists and `StreamPump.pump/3` already renders it as a visible ⚠
        # message -- this is its producer on the streaming run/2 path. The
        # `:done` payload's own shape is untouched (content/tool_results/usage)
        # so nothing reading it directly is disturbed.
        unexecuted_events =
          response
          |> Map.get(:tool_calls, [])
          |> Enum.map(&unexecuted_tool_call_event/1)

        done_event =
          {:done,
           %{
             content: response.content,
             tool_results: [],
             usage: response.usage,
             model: billed_model(response)
           }}

        {unexecuted_events ++ [done_event], :done}

      {:error, reason}, :running ->
        {[{:error, reason}], :done}

      _event, :done ->
        {:halt, :done}
    end)
  end

  defp unexecuted_tool_call_event(tool_call) do
    name =
      Map.get(tool_call, "name") || Map.get(tool_call, :name) || "unknown"

    {:tool_unexecuted, %{name: name, reason: :no_tool_loop}}
  end

  defp sync_completion(backend, messages, backend_opts) do
    Stream.resource(
      fn -> :pending end,
      fn
        :pending ->
          case backend.complete(messages, backend_opts) do
            {:ok, response} ->
              events = [
                {:text_delta, response.content},
                {:done,
                 %{
                   content: response.content,
                   tool_results: [],
                   usage: response.usage,
                   model: billed_model(response)
                 }}
              ]

              {events, :done}

            {:error, reason} ->
              {[{:error, reason}], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp error_stream(reason) do
    Stream.resource(
      fn -> :init end,
      fn
        :init -> {[{:error, reason}], :done}
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp receive_react_event(%{done: true} = state), do: {:halt, state}

  defp receive_react_event(%{ref: ref} = state) do
    receive do
      {:react_event, ^ref, event} ->
        case event do
          {:done, _} -> {[event], %{state | done: true}}
          {:error, _} -> {[event], %{state | done: true}}
          _ -> {[event], state}
        end

      {:react_done, ^ref} ->
        {:halt, state}
    after
      @react_timeout_ms -> {[{:error, :timeout}], %{state | done: true}}
    end
  end

  defp react_loop(_messages, iteration, %{max_iterations: max} = config)
       when iteration >= max do
    emit(config, {:error, :max_iterations_reached})
  end

  defp react_loop(messages, iteration, config) do
    case config.backend.complete(messages, config.opts) do
      {:ok, %{tool_calls: tool_calls} = response}
      when is_list(tool_calls) and tool_calls != [] ->
        handle_tool_turn(messages, iteration, config, response, tool_calls)

      {:ok, %{content: content} = response} ->
        accumulated = extract_tool_results(messages)

        emit(
          config,
          {:done,
           %{
             content: content,
             tool_results: accumulated,
             # The conversation as the loop actually built it, tool calls and
             # their results included. `content` alone is the conclusion
             # without the work: a consumer persisting a turn to resume it
             # later would otherwise reload an agent that knows what it
             # decided and not what it read.
             messages: messages ++ [%{role: :assistant, content: content}],
             usage: Map.get(response, :usage, %{}),
             model: billed_model(response)
           }}
        )

      {:error, reason} ->
        emit(config, {:error, reason})
    end
  end

  defp handle_tool_turn(messages, iteration, config, response, tool_calls) do
    turn_info = %{
      content: Map.get(response, :content, ""),
      usage: Map.get(response, :usage, %{}),
      model: billed_model(response),
      iteration: iteration
    }

    report_tool_turn_usage(config.context, turn_info)

    Enum.each(tool_calls, fn tc ->
      emit(
        config,
        {:tool_use,
         %{
           name: Map.get(tc, "name"),
           arguments: Map.get(tc, "arguments", %{}),
           id: Map.get(tc, "id")
         }}
      )
    end)

    tool_messages = execute_tools(tool_calls, config)
    emit(config, {:turn_complete, turn_info})

    assistant_msg = %{role: :assistant, content: format_tool_text(tool_calls)}
    next_messages = messages ++ [assistant_msg | tool_messages]

    react_loop(next_messages, iteration + 1, config)
  end

  # A provider response is billed before its requested tools execute. Publish
  # that usage before tool execution so cancellation or a tool failure cannot
  # erase spend that already happened. The ordinary `:turn_complete` event is
  # still emitted after tool results, preserving the public stream ordering.
  defp report_tool_turn_usage(%{tool_turn_usage_sink: sink}, info)
       when is_function(sink, 1),
       do: sink.(info)

  defp report_tool_turn_usage(_context, _info), do: :ok

  # The BILLED model, which is not always the configured one: given no :model
  # the backend substitutes its own default and reports here what it actually
  # charged for. Costing has to price that, not the request.
  defp billed_model(response) do
    response |> Map.get(:metadata, %{}) |> Map.get(:model)
  end

  defp emit(%{caller: caller, ref: ref}, event) do
    send(caller, {:react_event, ref, event})
  end

  defp execute_tools(tool_calls, config) do
    Enum.map(tool_calls, fn tc ->
      name = Map.get(tc, "name")
      {result_map, msg} = dispatch_tool(name, tc, config)
      emit(config, {:tool_result, Map.put(result_map, :id, Map.get(tc, "id"))})
      msg
    end)
  end

  defp dispatch_tool(name, tool_call, config) do
    case ToolConverter.dispatch_tool_call(
           tool_call,
           config.actions,
           config.context
         ) do
      {:ok, result} ->
        build_tool_response(name, result)

      {:ok, result, _commands} ->
        build_tool_response(name, result)

      {:error, reason} ->
        Logger.debug(fn -> "tool #{name} failed: #{inspect(reason)}" end)

        {%{name: name, result: {:error, reason}},
         %{role: :user, content: ToolConverter.public_error(name, reason)}}
    end
  end

  defp build_tool_response(name, result) do
    {%{name: name, result: result},
     %{
       role: :user,
       content: "[Tool result for #{name}]: #{Jason.encode!(result)}"
     }}
  end

  @tool_result_pattern ~r/\[Tool result for (.+?)\]: (.+)/

  defp extract_tool_results(messages) do
    Enum.flat_map(messages, &parse_tool_result_message/1)
  end

  defp parse_tool_result_message(%{content: "[Tool result for " <> _ = content})
       when is_binary(content) do
    case Regex.run(@tool_result_pattern, content) do
      [_, name, json] ->
        result =
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            _ -> json
          end

        [%{name: name, result: result}]

      _ ->
        []
    end
  end

  defp parse_tool_result_message(_), do: []

  # An `:executor` (or one resolved by `:auto_provider`) selects the backend
  # and base opts; otherwise `:backend`. `:backend_opts` override those, and
  # a top-level `:model` overrides everything (a mid-session `/model` switch).
  defp resolve_backend(opts) do
    with {:ok, backend, base_opts} <- backend_from_opts(opts) do
      backend_opts =
        base_opts
        |> Keyword.merge(Keyword.get(opts, :backend_opts, []))
        |> maybe_override_model(Keyword.get(opts, :model))
        |> maybe_inject_actions(backend, opts)

      {:ok, backend, backend_opts}
    end
  end

  # A backend that owns its tool loop needs the Action modules in its opts.
  defp maybe_inject_actions(backend_opts, backend, opts) do
    with true <- AIBackend.handles_tools_internally?(backend),
         actions when is_list(actions) and actions != [] <- Keyword.get(opts, :actions) do
      Keyword.put_new(backend_opts, :actions, actions)
    else
      _ -> backend_opts
    end
  end

  defp backend_from_opts(opts) do
    case Keyword.get(opts, :executor) || resolve_executor(opts) do
      %ExecutorConfig{} = executor ->
        case Selector.select(executor) do
          {:ok, backend, executor_opts} -> {:ok, backend, executor_opts}
          {:error, reason} -> {:error, {:backend_unavailable, reason}}
        end

      nil ->
        explicit_backend(opts)

      # Named by shape only: the value may carry credentials.
      _other ->
        {:error, {:invalid_executor, :not_an_executor_config}}
    end
  end

  defp explicit_backend(opts) do
    case Keyword.get(opts, :backend) do
      backend when is_atom(backend) and backend not in [nil, true, false] -> {:ok, backend, []}
      none when none in [nil, true, false] -> {:error, :no_backend}
      # Named by shape only, like the executor.
      _other -> {:error, {:invalid_backend, :not_a_module}}
    end
  end

  @doc false
  # `auto_provider: true` without an `:executor` resolves one through
  # `Raxol.Agent.Backend.Resolver` (op-ref -> provider env -> `AI_API_KEY`).
  # Nil when nothing resolves.
  @spec resolve_executor(keyword()) :: ExecutorConfig.t() | nil
  def resolve_executor(opts) do
    if Keyword.get(opts, :auto_provider, false) do
      resolver_opts =
        [
          harness: Keyword.get(opts, :provider),
          model: Keyword.get(opts, :model),
          api_key: Keyword.get(opts, :api_key),
          base_url: Keyword.get(opts, :base_url)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Resolver.resolve(resolver_opts) do
        {:ok, executor, _source} -> executor
        _ -> nil
      end
    end
  end

  defp maybe_override_model(backend_opts, nil), do: backend_opts

  defp maybe_override_model(backend_opts, model),
    do: Keyword.put(backend_opts, :model, model)

  defp build_messages(prompt, opts) when is_binary(prompt) do
    case Keyword.get(opts, :messages) do
      nil ->
        apply_system_prompt([%{role: :user, content: prompt}], opts)

      messages when is_list(messages) ->
        apply_system_prompt(messages, opts)
    end
  end

  defp build_messages(messages, opts) when is_list(messages),
    do: apply_system_prompt(messages, opts)

  # `:system_prompt` applies to EVERY message-entry form -- a system prompt
  # silently dropped because the caller happened to pass a pre-built list is
  # a trust bug (the operator believes a prompt governs the turn while the
  # backend never saw it). An explicit system message already present in the
  # list wins: the list is the more specific artifact, and we never inject a
  # duplicate.
  defp apply_system_prompt(messages, opts) do
    case Keyword.get(opts, :system_prompt) do
      nil ->
        messages

      sys when is_binary(sys) ->
        if Enum.any?(messages, &(Map.get(&1, :role) == :system)) do
          messages
        else
          [%{role: :system, content: sys} | messages]
        end
    end
  end

  defp format_tool_text(tool_calls) do
    names =
      Enum.map_join(tool_calls, ", ", fn tc ->
        Map.get(tc, "name", "unknown")
      end)

    "[Calling tools: #{names}]"
  end
end

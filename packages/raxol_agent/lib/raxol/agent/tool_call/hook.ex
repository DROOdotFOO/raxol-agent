defmodule Raxol.Agent.ToolCall.Hook do
  require Logger

  @moduledoc """
  Ordered interception pipeline around LLM tool-call execution.

  Every LLM-initiated tool call goes through
  `Raxol.Agent.Action.ToolConverter.dispatch_tool_call/3` (the react loops in
  `Raxol.Agent.Stream` and `Raxol.Agent.Strategy.ReAct`, and the Vfs/Payments
  helpers). Hooks run just before the Action and can observe, transform or veto
  it; `Raxol.Agent.McpSpendHook` reserves budget this way. `Pipeline`, `Direct`
  and `run_action*` call `Action.call/2` directly but are never LLM-reachable. A
  backend whose `handles_tools_internally?/0` is true bypasses these hooks.

  ## Contract

      defmodule MyGate do
        @behaviour Raxol.Agent.ToolCall.Hook

        @impl true
        def before_call(call, _context) do
          if allowed?(call), do: {:cont, call}, else: {:halt, :budget_exceeded}
        end
      end

    * `before_call(call, context)` returns `{:cont, call}` (possibly
      transformed) or `{:halt, reason}`.
    * `after_call(call, result, context)` (optional) may transform the result:
      `{:ok, output}`, `{:ok, output, commands}` or `{:error, reason}`.

  Hooks are listed under `:tool_call_hooks` in the agent context:

      Raxol.Agent.Stream.react(prompt,
        actions: [MyAction],
        context: %{tool_call_hooks: [SpendGate, AuditHook]}
      )

  Callbacks run in declared order. The first `{:halt, reason}` stops the chain
  and `{:error, {:vetoed, reason}}` flows back as a failed tool call.

  ## Failure containment

  A `before_call/2` that raises, throws or exits vetoes with
  `{:hook_raised | :hook_threw | :hook_exited, hook_module, detail}`; an exit is
  also logged at `:error` and emitted as `[:raxol, :agent, :tool_call_hook, :exit]`.
  Any other return, or a `{:cont, call}` whose `:action` is not an atom, is
  `{:error, {:hook_error, {:invalid_hook_return, hook_module, value}}}`, never a
  veto. Required keys a returned call omits are backfilled. A failing
  `after_call/3` passes the untransformed result through.

  ## Re-authorization

  When a hook changes `call.action` or `call.params`, the tool authorizer
  (`Raxol.Agent.ToolPolicy` or the context's `:tool_authorizer`) re-runs on the
  pair about to execute. A swapped action must be in the declared toolset and
  export `call/2`, or the call fails `{:error, {:tool_not_in_toolset, module}}`.
  A hook cannot smuggle a larger amount or an out-of-band tool past the policy.

  `Raxol.Agent.CommandHook` wraps Directive execution with the same idiom.
  """

  @typedoc "A tool call about to be executed."
  @type call :: %{
          action: module(),
          name: String.t(),
          params: map(),
          call_id: term()
        }

  @type context :: map()

  @type result ::
          {:ok, map()}
          | {:ok, map(), [Raxol.Agent.Directive.t()]}
          | {:error, term()}

  @doc """
  Called before the Action is executed.

  Return `{:cont, call}` to allow (optionally transformed -- later hooks see
  the modified call), or `{:halt, reason}` to veto the call.
  """
  @callback before_call(call(), context()) :: {:cont, call()} | {:halt, term()}

  @doc """
  Optional: called after the Action has executed.

  Receives the final call and the full result term; returns the (possibly
  transformed) result.
  """
  @callback after_call(call(), result(), context()) :: result()

  @optional_callbacks after_call: 3

  @context_key :tool_call_hooks

  @doc "Read the ordered hook list from an agent context (`[]` when unset)."
  @spec from_context(map()) :: [module()]
  def from_context(context) when is_map(context),
    do: Map.get(context, @context_key, [])

  def from_context(_context), do: []

  @doc """
  Run a call through the before-call pipeline in declared order.

  The first `{:halt, reason}` short-circuits the chain. Each hook may
  transform the call before passing it to the next (missing required keys
  are backfilled from the incoming call). A hook that raises, throws, or
  exits halts the chain with `{:halt, {:hook_raised | :hook_threw |
  :hook_exited, hook, detail}}` (contained -- never propagated). A
  `before_call/2` return that is neither `{:cont, call}` nor `{:halt,
  reason}` is a contract violation, not a veto: it returns `{:error,
  {:invalid_hook_return, hook, value}}` instead.
  """
  @spec run_before([module()], call(), context()) ::
          {:cont, call()} | {:halt, term()} | {:error, term()}
  def run_before([], call, _context), do: {:cont, call}

  def run_before([hook | rest], call, context) do
    case invoke_before(hook, call, context) do
      {:cont, call} -> run_before(rest, call, context)
      {:halt, _reason} = halted -> halted
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Run a result through the after-call pipeline in **declared order** (the same
  order `before_call/2` runs in -- this is a forward chain, not a stack
  unwind).

  Hooks that don't export `after_call/3` are skipped. A hook that raises,
  throws, or exits is contained: the result passes through unchanged (the
  Action already ran).
  """
  @spec run_after([module()], call(), result(), context()) :: result()
  def run_after(hooks, call, result, context) do
    Enum.reduce(hooks, result, fn hook, acc ->
      invoke_after(hook, call, acc, context)
    end)
  end

  defp invoke_before(hook, call, context) do
    case hook.before_call(call, context) do
      {:cont, %{} = returned} ->
        backfill_cont(hook, call, returned)

      {:halt, reason} ->
        {:halt, reason}

      other ->
        {:error, {:invalid_hook_return, hook, other}}
    end
  rescue
    error -> {:halt, {:hook_raised, hook, Exception.message(error)}}
  catch
    :throw, value -> {:halt, {:hook_threw, hook, value}}
    :exit, reason -> invoke_exit(hook, reason)
  end

  # Backfill any of the four required keys the hook dropped from the
  # pre-hook call; only keys the hook actually set take effect. This
  # tolerates a hook building a fresh map and forgetting e.g. call_id,
  # without masking a genuinely malformed return. A returned `:action` must
  # be a callable tool -- an Action module (atom) or a
  # `Raxol.Agent.Action.Dynamic` (a runtime-discovered tool). A bare `_` here
  # would let a hook hand back some other term that later crashes the tool
  # invocation with an uncontained error; `ToolConverter.assert_callable/1`
  # re-checks the executing action regardless. When the hook omits `:action`,
  # the original call's action carries through unchanged.
  defp backfill_cont(hook, call, returned) do
    action = Map.get(returned, :action, call.action)

    if callable_action?(action) do
      {:cont, Map.merge(call, Map.take(returned, [:action, :name, :params, :call_id]))}
    else
      {:error, {:invalid_hook_return, hook, {:cont, returned}}}
    end
  end

  defp callable_action?(action),
    do: is_atom(action) or match?(%Raxol.Agent.Action.Dynamic{}, action)

  defp invoke_exit(hook, reason) do
    Logger.error(fn -> "tool-call hook #{inspect(hook)} exited: #{inspect(reason)}" end)

    :telemetry.execute([:raxol, :agent, :tool_call_hook, :exit], %{}, %{
      hook: hook,
      reason: reason
    })

    {:halt, {:hook_exited, hook, reason}}
  end

  defp invoke_after(hook, call, result, context) do
    if function_exported?(hook, :after_call, 3) do
      hook.after_call(call, result, context)
    else
      result
    end
  rescue
    _error -> result
  catch
    # A contained after_call failure falls back to the un-transformed result --
    # the Action already ran, so we surface its real output, not a veto.
    :throw, _value -> result
    :exit, _reason -> result
  end
end

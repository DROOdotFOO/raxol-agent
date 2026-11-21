defmodule Raxol.AgentClientProtocol.Handler.Codegen do
  @moduledoc false
  # Compile-time codegen shared by `Agent` and `Client`: one `@callback` and one
  # overridable default per `MethodTable` row that has an app-level callback.
  # Protocol and session-control rows (`$/cancel_request`, `session/cancel`)
  # have no callback and are skipped.

  alias Raxol.AgentClientProtocol.MethodTable

  @type side :: :agent | :client

  @spec rows(side()) :: [MethodTable.row()]
  def rows(side) when side in [:agent, :client] do
    side |> MethodTable.rows_for_side() |> Enum.filter(&(&1.callback != nil))
  end

  # `params: nil` rows (e.g. `logout`) take only `ctx`.
  @spec callback_arities(side()) :: [{atom(), arity()}]
  def callback_arities(side) do
    Enum.map(rows(side), fn
      %{callback: cb, params: nil} -> {cb, 1}
      %{callback: cb} -> {cb, 2}
    end)
  end

  @spec callbacks(side()) :: [{atom(), arity(), String.t()}]
  def callbacks(side) do
    for row <- rows(side), do: {row.callback, if(row.params == nil, do: 1, else: 2), row.wire}
  end

  # The callbacks every handler behaviour declares besides the table rows.
  defmacro defcallbacks(side) do
    base =
      quote do
        @doc """
        Builds the handler state from `handler_arg`. Called once at Connection
        boot; the result is passed read-only as `ctx.handler_state`. Default:
        `{:ok, handler_arg}`.
        """
        @callback init(handler_arg :: term()) :: {:ok, handler_state :: term()} | {:stop, term()}

        @doc """
        Handles an underscore-prefixed extension request with no table row. Default:
        `{:error, Error.method_not_found()}`.
        """
        @callback handle_ext_request(wire :: String.t(), params :: map(), ctx()) ::
                    {:ok, map()} | {:error, Raxol.AgentClientProtocol.Error.t()} | :deferred

        @doc "Handles an underscore-prefixed extension notification. Default: `:ok`."
        @callback handle_ext_notification(wire :: String.t(), params :: map(), ctx()) :: term()
      end

    splice([base | side |> rows() |> Enum.map(&callback_clause/1)])
  end

  # The `use` body shared by `Agent` and `Client`: defaults for every callback,
  # all overridable. No `@impl` here: setting it in this quote's context would
  # make the compiler demand it on every generated default.
  @spec using(module(), side()) :: Macro.t()
  def using(behaviour, side) do
    quote do
      @behaviour unquote(behaviour)

      def init(arg), do: {:ok, arg}

      def handle_ext_request(_wire, _params, _ctx),
        do: {:error, Raxol.AgentClientProtocol.Error.method_not_found()}

      def handle_ext_notification(_wire, _params, _ctx), do: :ok

      unquote(splice(side |> rows() |> Enum.map(&default_clause/1)))

      defoverridable [init: 1, handle_ext_request: 3, handle_ext_notification: 3] ++
                       unquote(callback_arities(side))
    end
  end

  defp splice(clauses) do
    quote do
      (unquote_splicing(clauses))
    end
  end

  defp callback_clause(%{kind: :request, params: nil, callback: cb, result: result}) do
    quote do
      @callback unquote(cb)(Raxol.AgentClientProtocol.Connection.Ctx.t()) ::
                  {:ok, unquote(result).t()}
                  | {:error, Raxol.AgentClientProtocol.Error.t()}
                  | :deferred
    end
  end

  defp callback_clause(%{kind: :request, params: params, callback: cb, result: result}) do
    quote do
      @callback unquote(cb)(unquote(params).t(), Raxol.AgentClientProtocol.Connection.Ctx.t()) ::
                  {:ok, unquote(result).t()}
                  | {:error, Raxol.AgentClientProtocol.Error.t()}
                  | :deferred
    end
  end

  defp callback_clause(%{kind: :notification, params: params, callback: cb}) do
    quote do
      @callback unquote(cb)(unquote(params).t(), Raxol.AgentClientProtocol.Connection.Ctx.t()) ::
                  term()
    end
  end

  defp default_clause(%{kind: :request, params: nil, callback: cb}) do
    quote do
      def unquote(cb)(_ctx), do: {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
    end
  end

  defp default_clause(%{kind: :request, callback: cb}) do
    quote do
      def unquote(cb)(_params, _ctx),
        do: {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
    end
  end

  defp default_clause(%{kind: :notification, callback: cb}) do
    quote do
      def unquote(cb)(_params, _ctx), do: :ok
    end
  end
end

defmodule Raxol.Agent.McpTools.ToolDefinitions do
  @moduledoc false
  # The MCP tool definitions of `Raxol.Agent.McpTools`.

  alias Raxol.Agent.McpTools.Handlers

  @id_rule "an id is 1-64 characters of a-z 0-9 . _ - and starts with a letter or digit"
  # Under the 30 s an MCP client gives a tool call by default, so the tool's
  # own timeout answer reaches the client first.
  @max_timeout_ms 25_000

  @spec id_rule() :: String.t()
  def id_rule, do: @id_rule

  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc "A refusal is an answer, not a tool fault: it must not trip the registry's breaker."
  @spec fault?(term()) :: boolean()
  def fault?(reason), do: not is_binary(reason)

  @spec tools() :: [map()]
  def tools do
    [
      %{
        name: "agent_spawn",
        description:
          "Starts an agent in this server under an id you choose. Spawning a " <>
            "stopped id with the same app continues its journal; its state " <>
            "starts fresh. agent_list names the apps.",
        inputSchema: %{
          type: "object",
          required: ["app", "id"],
          properties: %{
            app: %{type: "string", description: "App name, from agent_list"},
            id: %{type: "string", description: "Agent id: " <> @id_rule}
          }
        },
        annotations: %{sensitive: true},
        callback: &Handlers.spawn/1,
        fault?: &fault?/1
      },
      %{
        name: "agent_list",
        description:
          "Lists the running agents this server started or exposes, and the " <>
            "apps agent_spawn starts.",
        inputSchema: %{type: "object", properties: %{}},
        callback: &Handlers.list/1,
        fault?: &fault?/1
      },
      %{
        name: "agent_ask",
        description: "Sends a message to an agent from agent_list and returns its reply.",
        inputSchema: %{
          type: "object",
          required: ["id", "message"],
          properties: %{
            id: %{type: "string", description: "Agent id"},
            message: %{type: "string", description: "The message"},
            timeout_ms: %{
              type: "integer",
              minimum: 1,
              maximum: @max_timeout_ms,
              description: "How long to wait for the reply (default #{@max_timeout_ms})"
            }
          }
        },
        annotations: %{sensitive: true},
        callback: &Handlers.ask/1,
        fault?: &fault?/1
      },
      %{
        name: "agent_status",
        description:
          "Reports the app, state (running, restarting or stopped), journal " <>
            "root, journal directory and journal size of an agent this server " <>
            "started or exposes.",
        inputSchema: id_schema(),
        callback: &Handlers.status/1,
        fault?: &fault?/1
      },
      %{
        name: "agent_stop",
        description: "Stops an agent from agent_list. Its journal stays readable.",
        inputSchema: id_schema(),
        annotations: %{sensitive: true},
        callback: &Handlers.stop/1,
        fault?: &fault?/1
      }
    ]
  end

  defp id_schema do
    %{
      type: "object",
      required: ["id"],
      properties: %{id: %{type: "string", description: "Agent id"}}
    }
  end
end

defmodule Raxol.Broker.Dashboard do
  @moduledoc """
  The broker's dashboard: one TEA app for the terminal, LiveView and SSH.

  It shows the mode, the account and its positions, the strategies and
  whether they run, the ASKs the executor has parked (with each rule id and
  prompt, and the time left before the executor denies it with
  `:ask_timeout`), and the last journal decisions.

  Keys: `j`/`k` move the focus between ASKs, `a` approves the focused ASK,
  `d` declines it, `r` re-reads the account, `q` quits. The focus is the
  ASK's group id, not its place in the list: when the focused ASK is
  answered elsewhere or times out, the focus is cleared and nothing is
  answered until `j` or `k` picks one again.

  ## Operator

  Only an operator may answer. The operator comes from the surface, never
  from application config, and is journaled as the approval's `by`:

    * terminal: `"terminal:<OS user>"` (the console of the broker's VM);
    * SSH: what the server's `:tenant_opts` function gives for the
      authenticated user, e.g.
      `tenant_opts: fn user -> {:ok, [dashboard: [operator: "ssh:" <> user]]} end`;
    * LiveView and headless: read-only. `Raxol.LiveView.TEALive` passes no
      per-user options to the app, so a browser session cannot be tied to a
      person here; `a` and `d` answer "read-only" and send nothing.

  The view keeps no timer of its own: the executor denies an unanswered ASK
  whether or not a dashboard is open. The view re-reads the executor and the
  journal once a second.

  ## Mounting

  The app has no surface-specific code:

      Raxol.run(Raxol.Broker.Dashboard)                           # terminal
      use Raxol.LiveView.TEALive, app_module: Raxol.Broker.Dashboard  # LiveView, read-only
      Raxol.SSH.serve(Raxol.Broker.Dashboard,
        port: 2222,
        authorized_keys_dir: dir,
        tenant_opts: fn user -> {:ok, [dashboard: [operator: "ssh:" <> user]]} end
      )

  It runs in the VM the broker runs in. It reads the processes registered
  under their default names; `config :raxol_broker, Raxol.Broker.Dashboard`
  (or a `:dashboard` keyword in the surface's options) names others:
  `:executor`, `:journal`, `:strategies`, `:client`.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Broker.{Executor, Journal, Mode, Response}
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Strategy

  @tick 1_000
  @call_timeout 2_000

  @impl true
  def init(context) do
    options = Map.get(context, :options, [])
    config = Keyword.merge(Application.get_env(:raxol_broker, __MODULE__, []), dashboard(options))
    environment = if is_list(options), do: Keyword.get(options, :environment)

    %{
      executor: Keyword.get(config, :executor, Executor),
      journal: Keyword.get(config, :journal, Journal),
      strategies: Keyword.get(config, :strategies, Strategy.Supervisor),
      client: Keyword.get(config, :client, Client),
      operator: operator(environment, dashboard(options)),
      asks: [],
      focus: nil,
      mode: :disarmed,
      runners: [],
      decisions: [],
      account: [],
      status: nil
    }
    |> refresh()
    |> read_account()
  end

  defp dashboard(options) when is_list(options), do: Keyword.get(options, :dashboard, [])
  defp dashboard(_options), do: []

  # Only the surface's own options name an operator; the terminal is the
  # console of the broker's VM, so its user is the operator.
  defp operator(environment, surface_options) when environment in [nil, :terminal] do
    Keyword.get_lazy(surface_options, :operator, fn ->
      "terminal:" <> (System.get_env("USER") || "unknown")
    end)
  end

  defp operator(_environment, surface_options) do
    case Keyword.get(surface_options, :operator) do
      operator when is_binary(operator) and operator != "" -> operator
      _none -> nil
    end
  end

  @impl true
  def update(message, model) do
    case message do
      :tick -> {refresh(model), []}
      key_match("j") -> {move(model, 1), []}
      key_match("k") -> {move(model, -1), []}
      key_match("a") -> {model |> answer(:approve) |> refresh(), []}
      key_match("d") -> {model |> answer(:decline) |> refresh(), []}
      key_match("r") -> {model |> refresh() |> read_account(), []}
      key_match("q") -> {model, [Directive.stop()]}
      _other -> {model, []}
    end
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick, :tick)]

  @impl true
  def view(model) do
    column style: %{gap: 0} do
      Enum.map(lines(model), &text/1)
    end
  end

  @doc "The dashboard's text, one line per entry (what `view/1` renders)."
  @spec lines(map()) :: [String.t()]
  def lines(model) do
    Enum.concat([
      ["Raxol Broker  mode: #{model.mode |> Atom.to_string() |> String.upcase()}"],
      model.account,
      ["", "strategies:"],
      runner_lines(model.runners),
      [
        "",
        "pending approvals (a approve, d deny, j/k move)" <>
          if(model.operator, do: ":", else: ", read-only:")
      ],
      ask_lines(model),
      ["", "recent decisions:"],
      decision_lines(model.decisions),
      status_lines(model.status)
    ])
  end

  defp runner_lines([]), do: ["  none"]
  defp runner_lines(runners), do: Enum.map(runners, &"  #{&1.id}  #{&1.strategy}  #{&1.status}")

  defp ask_lines(%{asks: []}), do: ["  none"]

  defp ask_lines(%{asks: asks, focus: focus}) do
    Enum.flat_map(asks, fn ask ->
      marker = if ask.group_id == focus, do: ">", else: " "

      left =
        div(
          max(DateTime.diff(ask.expires_at, DateTime.utc_now(), :millisecond), 0) + 59_999,
          60_000
        )

      ["#{marker} #{ask.intent.id}  #{intent_text(ask.intent)}  denied in #{left}m"] ++
        Enum.map(ask.prompts, fn {rule, prompt} -> "    #{rule}: #{prompt}" end)
    end)
  end

  defp decision_lines([]), do: ["  none"]

  defp decision_lines(decisions),
    do: Enum.map(decisions, &"  #{&1["at"]}  #{&1["intent"]}  #{&1["outcome"]}")

  defp status_lines(nil), do: []
  defp status_lines(status), do: ["", status]

  defp intent_text(intent) do
    [
      intent.kind,
      intent.side,
      intent.symbol,
      intent.qty,
      intent.limit && "@ #{intent.limit}",
      intent.notional
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp move(%{asks: []} = model, _step), do: model

  defp move(%{asks: asks, focus: focus} = model, step) do
    index =
      case Enum.find_index(asks, &(&1.group_id == focus)) do
        nil -> 0
        current -> (current + step) |> max(0) |> min(length(asks) - 1)
      end

    %{model | focus: Enum.at(asks, index).group_id}
  end

  defp answer(%{operator: nil} = model, _decision),
    do: %{model | status: "read-only: this surface has no operator; nothing sent"}

  defp answer(%{focus: nil} = model, _decision),
    do: %{model | status: "pick an approval with j/k first; nothing sent"}

  defp answer(model, decision) do
    case Enum.find(model.asks, &(&1.group_id == model.focus)) do
      nil ->
        %{model | focus: nil, status: "the focused approval is gone; nothing sent"}

      ask ->
        result =
          safe(fn ->
            case decision do
              :approve -> Executor.approve(model.executor, ask.group_id, model.operator)
              :decline -> Executor.decline(model.executor, ask.group_id, model.operator)
            end
          end)

        %{model | status: "#{decision} #{ask.intent.id}: #{describe(result)}"}
    end
  end

  defp describe({:ok, %{status: status}}), do: Atom.to_string(status)
  defp describe({:ok, :duplicate}), do: "duplicate"
  defp describe(:ok), do: "declined"
  defp describe({:deny, _group_id, {rule, _detail}}), do: "denied by #{rule}"
  defp describe({:ask, _group_id, _prompts}), do: "asked again"
  defp describe({:error, reason}), do: "error #{inspect(reason, structs: false)}"

  defp refresh(model) do
    asks = safe(fn -> Executor.parked(model.executor, @call_timeout) end)
    asks = if is_list(asks), do: asks, else: model.asks

    decisions =
      case safe(fn -> Journal.recent(model.journal, 5) end) do
        {:ok, decisions} -> decisions
        _unreadable -> model.decisions
      end

    %{
      model
      | asks: asks,
        focus: if(Enum.any?(asks, &(&1.group_id == model.focus)), do: model.focus),
        mode: Mode.current(model.journal),
        runners: Enum.map(Strategy.Supervisor.running(model.strategies), &elem(&1, 1)),
        decisions: decisions
    }
  end

  defp read_account(model) do
    lines =
      with {:ok, body} <- read(model.client, "get_accounts", %{}) do
        body
        |> Response.list(["accounts", "results"])
        |> Enum.filter(&(&1["agentic_allowed"] == true))
        |> Enum.flat_map(&account_lines(model.client, &1))
      end

    %{model | account: if(is_list(lines), do: lines, else: ["account: not connected"])}
  end

  defp account_lines(client, %{"account_number" => number} = account) do
    positions =
      case read(client, "get_equity_positions", %{"account_number" => number}) do
        {:ok, body} ->
          body
          |> Response.list(["positions", "results"])
          |> Enum.map_join(", ", &"#{&1["symbol"]} #{&1["quantity"] || &1["qty"]}")

        {:error, _reason} ->
          "unreadable"
      end

    [
      "account #{number}  buying power #{account["buying_power"] || "?"}",
      "positions: #{positions}"
    ]
  end

  defp read(client, tool, args),
    do: safe(fn -> Response.body(Client.call(client, tool, args)) end)

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:down, reason}}
  end
end

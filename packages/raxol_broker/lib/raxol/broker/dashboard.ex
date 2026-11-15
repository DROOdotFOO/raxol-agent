defmodule Raxol.Broker.Dashboard do
  @moduledoc """
  The broker's dashboard: one TEA app for the terminal, LiveView and SSH.

  It shows the mode, the account and its positions, the strategies and
  whether they run, the ASKs the executor has parked (with each rule id and
  prompt, and the time left before the executor denies it with
  `:ask_timeout`), and the last journal decisions.

  Keys: `j`/`k` move the focus between ASKs, `a` approves the focused ASK,
  `d` declines it, `K` and then `y` pull the kill switch
  (`Raxol.Broker.Halt.kill/1`; any other key cancels it), `r` re-reads the
  account, `q` quits. The focus is the ASK's group id, not its place in the
  list: when the focused ASK is answered elsewhere or times out, the focus
  is cleared and nothing is answered until `j` or `k` picks one again.

  ## Operator

  Only an operator may answer or kill. The operator comes from the surface,
  never from application config, and is journaled as the approval's `by`
  and the kill's trigger:

    * terminal: `"terminal:<OS user>"` (the console of the broker's VM);
    * SSH: what the server's `:tenant_opts` function gives for the
      authenticated user, e.g.
      `tenant_opts: fn user -> {:ok, [dashboard: [operator: "ssh:" <> user]]} end`;
    * LiveView and headless: read-only. `Raxol.LiveView.TEALive` passes no
      per-user options to the app, so a browser session cannot be tied to a
      person here; `a`, `d` and `K` answer "read-only" and send nothing.

  The executor denies an unanswered ASK whether or not a dashboard is open.
  Refreshes, account reads, heartbeats and operator actions run as independent
  TEA task directives, at most one per operation. A stalled dependency never
  blocks input or another operation. Approval and kill outcomes stay pending
  until their task answers; a slow call is not reported as "nothing sent".

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
  `:executor`, `:journal`, `:strategies`, `:client`, `:heartbeat`.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Broker.{Executor, Halt, Heartbeat, Journal, Response, Snapshot}
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
      heartbeat: Keyword.get(config, :heartbeat, Heartbeat),
      confirming_kill: false,
      in_flight: %{},
      errors: %{},
      account_loaded: false,
      asks: [],
      focus: nil,
      mode: :disarmed,
      runners: [],
      decisions: [],
      account: ["account: not connected"],
      status: nil
    }
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
  def update(:tick, model) do
    {model, effects} = refresh(model)
    {model, beat} = launch_beat(model)
    {model, account} = if model.account_loaded, do: {model, []}, else: launch_account(model)
    {model, effects ++ beat ++ account}
  end

  def update({:command_result, {:broker_dashboard, operation, ref, result}}, model) do
    if model.in_flight[operation] == ref do
      model = %{model | in_flight: Map.delete(model.in_flight, operation)}
      complete(operation, result, model)
    else
      {model, []}
    end
  end

  def update(key_match("y"), %{confirming_kill: true} = model), do: kill(model)

  def update(%Raxol.Core.Events.Event{type: :key}, %{confirming_kill: true} = model) do
    status =
      if Map.has_key?(model.in_flight, :answer) or Map.has_key?(model.in_flight, :kill),
        do: "kill confirmation cancelled; earlier action outcome still pending",
        else: "kill cancelled; nothing sent"

    {%{model | confirming_kill: false, status: status}, []}
  end

  def update(message, model) do
    case message do
      key_match("j") -> {move(model, 1), []}
      key_match("k") -> {move(model, -1), []}
      key_match("a") -> answer(model, :approve)
      key_match("d") -> answer(model, :decline)
      key_match("r") ->
        {model, effects} = refresh(model)
        {model, account} = launch_account(model)
        {model, effects ++ account}
      key_match("K") -> {confirm_kill(model), []}
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
      Enum.map(
        Enum.sort(Map.keys(model.errors)),
        &"#{&1} unavailable; outcome or snapshot unconfirmed"
      ),
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
    do: {%{model | status: "read-only: this surface has no operator; nothing sent"}, []}

  defp answer(%{in_flight: pending} = model, _decision)
       when is_map_key(pending, :answer) or is_map_key(pending, :kill),
       do: {model, []}

  defp answer(%{focus: nil} = model, _decision),
    do: {%{model | status: "pick an approval with j/k first; nothing sent"}, []}

  defp answer(model, decision) do
    cond do
      ask = Enum.find(model.asks, &(&1.group_id == model.focus)) ->
        model = %{model | status: "#{decision} #{ask.intent.id}: pending; outcome not yet known"}

        launch(model, :answer, fn ->
          result =
            case decision do
              :approve -> Executor.approve(model.executor, ask.group_id, model.operator)
              :decline -> Executor.decline(model.executor, ask.group_id, model.operator)
            end

          {decision, ask.intent.id, result}
        end)

      true ->
        {%{model | focus: nil, status: "the focused approval is gone; nothing sent"}, []}
    end
  end

  defp describe({:ok, %{status: status}}), do: Atom.to_string(status)
  defp describe({:ok, :duplicate}), do: "duplicate"
  defp describe(:ok), do: "declined"
  defp describe({:deny, _group_id, {rule, _detail}}), do: "denied by #{rule}"
  defp describe({:ask, _group_id, _prompts}), do: "asked again"
  defp describe({:error, reason}), do: "error #{inspect(reason, structs: false)}"

  # Independent from refresh: a stalled executor must not starve the heartbeat.
  defp launch_beat(%{operator: nil} = model), do: {model, []}

  defp launch_beat(model) do
    launch(model, :heartbeat, fn ->
      if GenServer.whereis(model.heartbeat),
        do: Heartbeat.beat(model.heartbeat, model.operator),
        else: {:error, :heartbeat_not_running}
    end)
  end

  defp confirm_kill(%{operator: nil} = model),
    do: %{model | status: "read-only: this surface has no operator; nothing sent"}

  defp confirm_kill(model) do
    %{
      model
      | confirming_kill: true,
        status:
          "kill: disarm, stop strategies, cancel open orders? y to confirm, any key to cancel"
    }
  end

  defp kill(model) do
    if Map.has_key?(model.in_flight, :kill) do
      {%{model | confirming_kill: false}, []}
    else
      opts = [
        executor: model.executor,
        journal: model.journal,
        strategies: model.strategies,
        trigger: model.operator
      ]

      model = %{model | confirming_kill: false, status: "kill pending; outcome not yet known"}
      launch(model, :kill, fn -> Halt.kill(opts) end)
    end
  end

  defp refresh(model) do
    [
      {:executor, fn -> Executor.parked(model.executor, @call_timeout) end},
      {:journal, fn ->
        with {:ok, decisions} <- Journal.recent(model.journal, 5),
             {:ok, mode, _record} <- Journal.mode(model.journal) do
          {:ok, mode, decisions}
        end
      end},
      {:strategies, fn ->
        Enum.map(Strategy.Supervisor.running(model.strategies), &elem(&1, 1))
      end}
    ]
    |> Enum.reduce({model, []}, fn {operation, fun}, {model, effects} ->
      {model, next} = launch(model, operation, fun)
      {model, effects ++ next}
    end)
  end

  defp launch_account(model),
    do: launch(model, :account, fn -> read_account(model).account end)

  defp launch(model, operation, fun) do
    if Map.has_key?(model.in_flight, operation) do
      {model, []}
    else
      ref = make_ref()

      effect =
        Directive.spawn_task(fn ->
          {:broker_dashboard, operation, ref, safe(fun)}
        end)

      {%{model | in_flight: Map.put(model.in_flight, operation, ref)}, [effect]}
    end
  end

  defp complete(:executor, asks, model) when is_list(asks) do
    model = %{
      model
      | asks: asks,
        focus: if(Enum.any?(asks, &(&1.group_id == model.focus)), do: model.focus)
    }

    {clear_error(model, :executor), []}
  end

  defp complete(:journal, {:ok, mode, decisions}, model),
    do: {clear_error(%{model | mode: mode, decisions: decisions}, :journal), []}

  defp complete(:strategies, runners, model) when is_list(runners),
    do: {clear_error(%{model | runners: runners}, :strategies), []}

  defp complete(:account, account, model) when is_list(account),
    do: {clear_error(%{model | account: account, account_loaded: true}, :account), []}

  defp complete(:heartbeat, :ok, model), do: {clear_error(model, :heartbeat), []}

  defp complete(:answer, {decision, id, result}, model) do
    refresh(%{clear_error(model, :answer) | status: "#{decision} #{id}: #{describe(result)}"})
  end

  defp complete(:kill, {:ok, summary}, model) do
    refresh(%{model | status: "killed: #{length(summary.results)} cancel(s) and decline(s) sent"})
  end

  defp complete(operation, {:error, reason}, model) do
    model = %{model | errors: Map.put(model.errors, operation, reason)}
    model = if operation == :journal, do: %{model | mode: :disarmed}, else: model

    if operation in [:answer, :kill] do
      {%{model | status: "#{operation} outcome unconfirmed: #{inspect(reason, structs: false)}"},
       []}
    else
      {model, []}
    end
  end

  defp clear_error(model, operation),
    do: %{model | errors: Map.delete(model.errors, operation)}

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

  defp account_lines(client, %{"account_number" => number}) do
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
      "account #{number}  buying power #{or_unknown(safe(fn -> Snapshot.buying_power(client, number) end))}",
      "positions: #{positions}"
    ]
  end

  defp or_unknown(value) when is_binary(value), do: value
  defp or_unknown(_unreadable), do: "?"

  defp read(client, tool, args),
    do: safe(fn -> Response.body(Client.call(client, tool, args)) end)

  defp safe(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:down, reason}}
  end
end

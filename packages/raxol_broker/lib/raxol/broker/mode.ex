defmodule Raxol.Broker.Mode do
  @moduledoc """
  Armed or disarmed, as the latest `mode` record in `Raxol.Broker.Journal`
  says. A journal with no mode record, or one that cannot be read, is
  disarmed.

  `Raxol.Broker.Executor` sends no order tool unless the broker is armed:
  a disarmed executor journals a minimal intent/context group with
  `mode: :dry_run` and closes it as `not_armed`, without context reads or
  policy evaluation. A group parked or in review when disarmed is closed
  the same way before `placing`. Only the kill's human cancels and declines
  bypass arming.

  ## Arming

  `arm/1` writes an `armed` record only when every check passes, in this
  order:

    1. the policy file loads (`Raxol.Broker.PolicyFile.load/1`);
    2. the journal's chain verifies on disk (`Raxol.Broker.Journal.verify/1`
       is `:ok`), so a journal edited by even one byte cannot be armed;
    3. the read-only client is connected (it lists its tools);
    4. `get_accounts` marks `:account` as the one agentic account
       (`Raxol.Broker.AccountPin`);
    5. `get_trade_approval_setting` for that account reads
       `human_must_approve_trades: true`, shown in the confirmation and
       journaled with the `armed` record (only the owner can change it, in
       the app); `false` refuses with `{:approvals_off, account}`;
    6. every added strategy's symbols quote at or below the policy's
       `max_notional_per_order`, because limit orders are whole shares and
       a share above the cap could never be bought;
    7. the person arming types `ARM` after reading what was checked.

  Any mode change during the checks invalidates their journal generation.
  The final append checks that generation and the halt marker inside the
  journal process, so an old confirmation cannot undo a completed kill.

  `disarm/2` is unconditional: it writes a `disarmed` record whatever the
  state. Only a damaged journal refuses it, and a damaged journal refuses
  every order as well.

  ## Options for `arm/1`

  `:account` (required: the account the executor trades), `:journal`
  (default `Raxol.Broker.Journal`), `:client` (the read-only
  `Raxol.Broker.MCP.Client`, default that module), `:policy_path` (default
  `broker.policy.exs`), `:confirm` (required: a one-arity function given the
  summary lines, returning what the person typed), `:by` (who armed,
  default `"cli"`), `:strategies` (the strategy supervisor, default
  `Raxol.Broker.Strategy.Supervisor`).

  A successful arm resumes every runner the drawdown breaker paused
  (`Raxol.Broker.Halt.pause/2`): only a fresh arm does.
  """

  alias Raxol.Broker.{AccountPin, Feed, Journal, PolicyFile, Response, Strategy}
  alias Raxol.Broker.MCP.Client

  @confirmation "ARM"

  @doc "`:armed` or `:disarmed`."
  @spec current(Journal.server()) :: :armed | :disarmed
  def current(journal \\ Journal) do
    with false <- Journal.halt_pending?(journal),
         {:ok, :armed, _record} <- Journal.mode(journal) do
      :armed
    else
      _disarmed_or_unreadable -> :disarmed
    end
  end

  @doc "Write a `disarmed` record with `reason`; see the moduledoc."
  @spec disarm(String.t(), keyword()) :: :ok | {:error, term()}
  def disarm(reason, opts \\ []) when is_binary(reason) do
    fields = %{"reason" => reason, "by" => Keyword.get(opts, :by, "cli")}
    Journal.record_disarmed(fields, Keyword.get(opts, :journal, Journal))
  end

  @doc """
  Run the arming checks and write an `armed` record. `{:ok, fields}` with
  what was recorded, or `{:error, reason}` naming the first check that
  failed; nothing is written then.
  """
  @spec arm(keyword()) :: {:ok, map()} | {:error, term()}
  def arm(opts) do
    journal = Keyword.get(opts, :journal, Journal)
    client = Keyword.get(opts, :client, Client)
    path = Keyword.get(opts, :policy_path, PolicyFile.filename())
    account = Keyword.fetch!(opts, :account)
    confirm = Keyword.fetch!(opts, :confirm)

    with {:ok, policy} <- policy(path),
         {:ok, generation} <- Journal.arm_generation(journal),
         :ok <- verified(journal),
         :ok <- connected(client),
         false <- Journal.halt_pending?(journal),
         :ok <- AccountPin.check(read(client, "get_accounts", %{}), account),
         {:ok, approvals?} <- approval_setting(client, account),
         {:ok, quotes} <- strategy_quotes(journal, client, policy),
         fields = record(policy, quotes, account, approvals?, Keyword.get(opts, :by, "cli")),
         :ok <- confirmed(confirm.(summary(path, fields))),
         false <- Journal.halt_pending?(journal),
         :ok <- Journal.record_armed(fields, journal, generation) do
      supervisor = Keyword.get(opts, :strategies, Strategy.Supervisor)
      Strategy.Supervisor.resume_all(:drawdown_halt, supervisor: supervisor)
      {:ok, fields}
    else
      true -> {:error, :halt_requested}
      {:error, _reason} = error -> error
    end
  end

  defp policy(path) do
    case PolicyFile.load(path) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:error, {:policy, reason}}
    end
  end

  defp verified(journal) do
    case Journal.verify(journal) do
      :ok -> :ok
      other -> {:error, {:journal, other}}
    end
  catch
    :exit, reason -> {:error, {:journal, {:down, reason}}}
  end

  defp connected(client) do
    case Client.list_tools(client) do
      {:ok, _tools} -> :ok
      {:error, reason} -> {:error, {:not_connected, reason}}
    end
  catch
    :exit, reason -> {:error, {:not_connected, {:down, reason}}}
  end

  defp strategy_quotes(journal, client, policy) do
    with {:ok, specs} <- Journal.strategies(journal),
         {:ok, symbols} <- symbols(specs) do
      if symbols == [], do: {:ok, %{}}, else: within_cap(client, symbols, policy)
    end
  end

  defp symbols(specs) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
      case Strategy.symbols(spec) do
        {:ok, symbols} -> {:cont, {:ok, acc ++ symbols}}
        {:error, reason} -> {:halt, {:error, {:strategy, spec["id"], reason}}}
      end
    end)
    |> case do
      {:ok, symbols} -> {:ok, symbols |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp within_cap(client, symbols, policy) do
    cap = Keyword.fetch!(policy, :max_notional_per_order)

    with {:ok, body} <- quote_body(client, symbols) do
      quotes = Feed.quotes(body)

      Enum.reduce_while(symbols, {:ok, %{}}, fn symbol, {:ok, acc} ->
        case Map.fetch(quotes, symbol) do
          {:ok, %{last: last}} ->
            if Decimal.gt?(last, cap),
              do: {:halt, {:error, {:quote_above_cap, symbol, last, cap}}},
              else: {:cont, {:ok, Map.put(acc, symbol, last)}}

          :error ->
            {:halt, {:error, {:no_quote, symbol}}}
        end
      end)
    end
  end

  defp quote_body(client, symbols) do
    case Response.body(Client.call(client, "get_equity_quotes", %{"symbols" => symbols})) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:quotes, reason}}
    end
  catch
    :exit, reason -> {:error, {:quotes, {:down, reason}}}
  end

  defp approval_setting(client, account) do
    case read(client, "get_trade_approval_setting", %{"account_number" => account}) do
      {:ok, %{"setting" => %{"human_must_approve_trades" => true}}} ->
        {:ok, true}

      {:ok, %{"setting" => %{"human_must_approve_trades" => false}}} ->
        {:error, {:approvals_off, account}}

      {:ok, _other} ->
        {:error, {:approval_setting, :unreadable}}

      {:error, reason} ->
        {:error, {:approval_setting, reason}}
    end
  end

  defp read(client, tool, args) do
    Response.body(Client.call(client, tool, args))
  catch
    :exit, reason -> {:error, {:down, reason}}
  end

  defp record(policy, quotes, account, approvals?, by) do
    %{
      "by" => by,
      "account_number" => account,
      "human_must_approve_trades" => approvals?,
      "max_notional_per_order" => Decimal.to_string(policy[:max_notional_per_order]),
      "daily_notional_cap" => Decimal.to_string(policy[:daily_notional_cap]),
      "quotes" => Map.new(quotes, fn {symbol, last} -> {symbol, Decimal.to_string(last)} end)
    }
  end

  defp summary(path, fields) do
    quotes = Enum.map(Enum.sort(fields["quotes"]), fn {s, p} -> "  #{s} last #{p}" end)
    approvals = if fields["human_must_approve_trades"], do: "on", else: "OFF"

    [
      "policy #{path}: max per order #{fields["max_notional_per_order"]}, " <>
        "daily cap #{fields["daily_notional_cap"]}",
      "journal verified",
      "client connected",
      "account #{fields["account_number"]} is the agentic account",
      "trade approvals in the Robinhood app: #{approvals} " <>
        "(human_must_approve_trades: #{fields["human_must_approve_trades"]})",
      "strategy symbols:" | if(quotes == [], do: ["  none"], else: quotes)
    ] ++ ["Type #{@confirmation} to place real orders:"]
  end

  defp confirmed(@confirmation), do: :ok
  defp confirmed(_answer), do: {:error, :not_confirmed}
end

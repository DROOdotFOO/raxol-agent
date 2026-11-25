defmodule Raxol.Broker.JournalTest do
  @moduledoc """
  Writing journal groups: the claim, entry rules, placing gates and the
  codec (see `Raxol.Broker.Test.JournalCase`).
  """
  use Raxol.Broker.Test.JournalCase, async: true

  alias Raxol.Broker.{Intent, Journal, Policy}
  alias Raxol.Broker.Journal.Codec
  alias Raxol.Broker.Test.{ExecutorIdentity, Hostile, JournalCase}

  @t0 JournalCase.t0()
  @day JournalCase.day()

  describe "writing groups" do
    test "a whole group lands as contiguous records sharing one group id", %{
      opts: opts,
      path: path
    } do
      start!(opts)
      intent = limit("2")
      ctx = context()

      assert {:ok, id} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: placed_entries(intent, ctx)},
                 opts[:name]
               )

      records = records(path)

      assert Enum.map(records, & &1["type"]) ==
               ~w(intent context verdict review verdict placing order)

      assert Enum.all?(records, &(&1["group_id"] == id))
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..7)
      assert %{"type" => "placing", "notional" => "250"} = Enum.at(records, 5)

      [intent_record, context_record | _] = records
      assert Codec.decode_intent(intent_record["intent"]) == {:ok, intent}
      assert Codec.decode_context(context_record["context"]) == {:ok, ctx}

      assert Journal.today_notional(@day, opts[:name]) == {:ok, d("250")}
      assert Journal.verify(opts[:name]) == :ok
    end

    test "write-ahead: the intent is on disk before any verdict, and a deny finishes the group",
         %{opts: opts, path: path} do
      start!(opts)
      intent = limit("100")
      ctx = context()

      assert {:ok, id} = Journal.open_group(intent, ctx, opts[:name])
      assert Enum.map(records(path), & &1["type"]) == ~w(intent context)

      {:deny, {:max_notional_per_order, _}} = verdict = Policy.evaluate(intent, ctx)
      assert :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, opts[:name])

      assert Journal.append_to_group(id, {:review, %{}}, opts[:name]) ==
               {:error, {:unknown_or_finished_group, id}}

      assert Journal.today_notional(@day, opts[:name]) == {:ok, d("0")}
    end

    test "invalid entries are refused and append nothing", %{opts: opts, path: path} do
      start!(opts)
      intent = limit("2")
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, opts[:name])

      assert {:error, {:invalid_entry, _}} =
               Journal.append_to_group(id, {:verdict, :final, {:allow, intent}}, opts[:name])

      assert {:error, {:invalid_result, _}} =
               Journal.append_to_group(id, {:verdict, :pre_review, :yes}, opts[:name])

      # Nothing may follow the terminal record of a one-shot group either.
      entries = Enum.concat(placed_entries(intent, ctx), [{:review, %{}}])

      assert {:error, {:group_finished, _}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: entries},
                 opts[:name]
               )

      assert length(records(path)) == 2
    end

    test "an order response is refused before placing, in either write path",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, name)

      assert Journal.append_to_group(id, {:order, :placed, %{}}, name) ==
               {:error, {:not_placing, id}}

      entries = List.delete(placed_entries(intent, ctx), {:placing})

      assert {:error, {:not_placing, _}} =
               Journal.append_group(%{intent: intent, context: ctx, entries: entries}, name)

      assert length(records(path)) == 2
      assert Journal.orders_last_minute(@t0, name) == {:ok, 0}
    end

    test "placing an order the journal cannot price is refused", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      {:ok, intent} = Intent.buy_shares("MSFT", d("3"), provenance: :strategy)
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, name)
      reviewed = [{:review, %{"warnings" => []}}, {:verdict, :post_review, {:allow, intent}}]
      Enum.each(reviewed, &(:ok = Journal.append_to_group(id, &1, name)))

      assert {:error, {:unpriced_order, _reason}} =
               Journal.append_to_group(id, {:placing}, name)

      assert {:error, {:unpriced_order, _reason}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: Enum.concat(reviewed, [{:placing}])},
                 name
               )

      assert Enum.map(records(path), & &1["type"]) == ~w(intent context review verdict)

      assert Journal.append_to_group(id, {:order, :placed, %{}}, name) ==
               {:error, {:not_placing, id}}
    end

    test "after placing only an order response or a close is taken", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      id = in_flight!(name, intent, ctx)

      for entry <- [
            {:placing},
            {:review, %{}},
            {:approval, :approved, "operator"},
            {:verdict, :post_review, Policy.evaluate(intent, ctx)}
          ] do
        assert Journal.append_to_group(id, entry, name) == {:error, {:already_placing, id}}
      end

      assert :ok = Journal.append_to_group(id, {:order, :placed, %{}}, name)
    end

    test "a process that does not hold the claim can write no group record",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, name)

      placed_entries(intent, ctx)
      |> Enum.take(1)
      |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))

      before = records(path)

      # A forged review, a post-review verdict or approval to unlock placing,
      # a close to end the executor's group, or placing itself: all refused.
      forged = [
        {:review, %{"warnings" => []}},
        {:verdict, :post_review, Policy.evaluate(intent, ctx)},
        {:approval, :approved, "mallory"},
        {:close, :forged},
        {:placing}
      ]

      other =
        Task.async(fn ->
          for entry <- forged, do: Journal.append_to_group(id, entry, name)
        end)

      assert Task.await(other) == List.duplicate({:error, {:not_claimant, id}}, length(forged))

      group = %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)}

      other =
        Task.async(fn ->
          {Journal.open_group(limit("2"), ctx, name), Journal.append_group(group, name)}
        end)

      assert Task.await(other) ==
               {{:error, {:not_claimant, nil}}, {:error, {:not_claimant, nil}}}

      assert records(path) == before
      assert Journal.open_groups(name) == {:ok, [id]}

      placed_entries(intent, ctx)
      |> Enum.slice(1..3)
      |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))
    end

    test "placing is refused without a review, and on an ASK without approval",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      intent = limit("2")
      allow = Policy.evaluate(intent, ctx)

      # An ALLOW with no review record.
      {:ok, id} = Journal.open_group(intent, ctx, name)
      :ok = Journal.append_to_group(id, {:verdict, :pre_review, allow}, name)
      :ok = Journal.append_to_group(id, {:verdict, :post_review, allow}, name)
      assert Journal.append_to_group(id, {:placing}, name) == {:error, {:not_reviewed, id}}

      # A review with no post-review verdict.
      {:ok, id} = Journal.open_group(limit("2"), ctx, name)
      :ok = Journal.append_to_group(id, {:review, %{"warnings" => []}}, name)
      assert Journal.append_to_group(id, {:placing}, name) == {:error, {:not_reviewed, id}}

      # An ASK, reviewed, never approved.
      {:ok, ask_intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :llm)
      {:ask, _} = ask = Policy.evaluate(ask_intent, ctx)

      entries = [
        {:verdict, :pre_review, ask},
        {:review, %{"warnings" => []}},
        {:verdict, :post_review, ask},
        {:placing}
      ]

      assert {:error, {:not_reviewed, _}} =
               Journal.append_group(%{intent: ask_intent, context: ctx, entries: entries}, name)

      refute Enum.any?(records(path), &(&1["type"] == "placing"))
    end

    test "a reviewed ASK with an approval may be placed", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      {:ok, intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :llm)
      {:ask, _} = ask = Policy.evaluate(intent, ctx)

      entries = [
        {:verdict, :pre_review, ask},
        {:review, %{"warnings" => []}},
        {:verdict, :post_review, ask},
        {:approval, :approved, "operator"},
        {:placing}
      ]

      assert {:ok, id} =
               Journal.append_group(%{intent: intent, context: ctx, entries: entries}, name)

      assert %{"type" => "placing", "group_id" => ^id} = List.last(records(path))
    end

    test "a second placing for the same intent is refused until the first fails",
         %{opts: opts} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      intent = limit("2")
      first = in_flight!(name, intent, ctx)

      {:ok, second} = Journal.open_group(intent, ctx, name)

      placed_entries(intent, ctx)
      |> Enum.take(3)
      |> Enum.each(&(:ok = Journal.append_to_group(second, &1, name)))

      assert Journal.append_to_group(second, {:placing}, name) ==
               {:error, {:duplicate_intent, first}}

      assert {:error, {:duplicate_intent, ^first}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: placed_entries(intent, ctx)},
                 name
               )

      assert Journal.placing_for_intent(intent.id, name) == {:ok, first}

      :ok = Journal.append_to_group(first, {:order, :failed, %{"error" => "rejected"}}, name)
      assert Journal.placing_for_intent(intent.id, name) == {:ok, nil}

      assert :ok = Journal.append_to_group(second, {:placing}, name)
      assert Journal.placing_for_intent(intent.id, name) == {:ok, second}
    end

    test "the intent index rebuilt on start skips failed orders", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      failed = limit("2")
      placed = limit("2")

      entries =
        List.replace_at(placed_entries(failed, ctx), -1, {:order, :failed, %{"error" => "no"}})

      {:ok, _} = Journal.append_group(%{intent: failed, context: ctx, entries: entries}, name)

      {:ok, placed_id} =
        Journal.append_group(
          %{intent: placed, context: ctx, entries: placed_entries(placed, ctx)},
          name
        )

      stop_supervised!(name)
      start!(opts)

      assert Journal.placing_for_intent(failed.id, name) == {:ok, nil}
      assert Journal.placing_for_intent(placed.id, name) == {:ok, placed_id}

      assert {:ok, _} =
               Journal.append_group(
                 %{intent: failed, context: ctx, entries: placed_entries(failed, ctx)},
                 name
               )

      assert {:error, {:duplicate_intent, ^placed_id}} =
               Journal.append_group(
                 %{intent: placed, context: ctx, entries: placed_entries(placed, ctx)},
                 name
               )
    end

    test "a second live claimant is refused; the claim is released when the claimant dies",
         %{opts: opts} do
      name = opts[:name]
      start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      parent = self()

      claimant =
        spawn(fn ->
          ExecutorIdentity.assume!(name)
          send(parent, {:claimed, Journal.claim(name)})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:claimed, :ok}
      Process.put(:"$initial_call", {Raxol.Broker.Executor, :init, 1})
      assert Journal.claim(name) == {:error, {:journal_claimed, claimant}}

      ref = Process.monitor(claimant)
      send(claimant, :stop)
      assert_receive {:DOWN, ^ref, :process, ^claimant, _}

      # The claimant is dead, so the claim is free even if the journal has
      # not yet handled its :DOWN.
      assert Journal.claim(name) == :ok
      assert Journal.claim(name) == :ok
    end

    test "with no claim held a plain process can neither claim nor write a group",
         %{opts: opts, path: path} do
      name = opts[:name]
      start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      intent = limit("2")
      ctx = context()
      group = %{intent: intent, context: ctx, entries: placed_entries(intent, ctx)}

      # The claim is free, and still a plain process is refused it.
      assert Journal.claim(name) == {:error, :not_an_executor}
      assert Journal.open_group(intent, ctx, name) == {:error, :unclaimed}
      assert Journal.append_group(group, name) == {:error, :unclaimed}
      assert Journal.append_to_group("any-group", {:placing}, name) == {:error, :unclaimed}
      assert records(path) == []
      assert Journal.open_groups(name) == {:ok, []}
    end

    # The threat-model limit: the journal identifies an Executor by its
    # proc_lib initial call, which a process can forge in its own dictionary.
    # Doing so is deliberate subversion, not a path through the public API.
    test "a process impersonating an Executor can claim and write placing", %{opts: opts} do
      name = opts[:name]
      start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      intent = limit("2")
      ctx = context()

      impostor =
        Task.async(fn ->
          Process.put(:"$initial_call", {Raxol.Broker.Executor, :init, 1})
          :ok = Journal.claim(name)
          {:ok, id} = Journal.open_group(intent, ctx, name)

          placed_entries(intent, ctx)
          |> Enum.take(4)
          |> Enum.map(&Journal.append_to_group(id, &1, name))
        end)

      assert Task.await(impostor) == [:ok, :ok, :ok, :ok]
    end

    # The claimant check comes before the journal reads anything the caller
    # sent: a struct whose Enumerable or Inspect would run on encode is
    # refused untouched, and the journal stays up.
    test "a non-claimant's struct context is refused before it is read", %{opts: opts, path: path} do
      name = opts[:name]
      journal = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      hostile = context(quotes: Hostile.new(), positions: Hostile.new())
      intent = limit("2")
      group = %{intent: intent, context: hostile, entries: []}

      assert Journal.open_group(intent, hostile, name) == {:error, :unclaimed}
      assert Journal.append_group(group, name) == {:error, :unclaimed}

      parent = self()

      claimant =
        spawn(fn ->
          ExecutorIdentity.assume!(name)
          send(parent, :claimed)
          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> send(claimant, :stop) end)
      assert_receive :claimed

      assert Journal.open_group(intent, hostile, name) == {:error, {:not_claimant, nil}}
      assert Journal.append_group(group, name) == {:error, {:not_claimant, nil}}

      assert Process.alive?(journal)
      assert Journal.open_groups(name) == {:ok, []}
      refute_received {:hostile, _callback}
      assert records(path) == []
    end

    test "a claimant's struct intent or context is refused by normalize, and nothing is written",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      intent = limit("2")
      ctx = context()
      hostile_ctx = context(quotes: %{"AAPL" => Hostile.new()})
      hostile_intent = %{intent | strategy: Hostile.new()}

      assert {:error, {:invalid_context, {:not_plain, [:quotes | _]}}} =
               Journal.open_group(intent, hostile_ctx, name)

      assert {:error, {:invalid_context, {:not_plain, [:quotes | _]}}} =
               Journal.append_group(
                 %{intent: intent, context: hostile_ctx, entries: placed_entries(intent, ctx)},
                 name
               )

      assert {:error, {:invalid_intent, {:not_plain, [:strategy | _]}}} =
               Journal.open_group(hostile_intent, ctx, name)

      assert Process.alive?(journal)
      refute_received {:hostile, _callback}
      assert records(path) == []
      assert Journal.open_groups(name) == {:ok, []}
      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
    end

    test "refuses an over-large decimal cleanly and stays alive", %{opts: opts} do
      name = opts[:name]
      journal = start!(opts)
      intent = limit("2")
      huge = %Decimal{sign: 1, coef: Integer.pow(10, 40), exp: 0}

      assert {:error, {:invalid_context, {:not_plain, [:quotes, "AAPL"]}}} =
               Journal.open_group(intent, context(quotes: %{"AAPL" => huge}), name)

      assert {:error, {:invalid_intent, {:not_plain, [:qty]}}} =
               Journal.open_group(%{intent | qty: %{huge | coef: 1, exp: 41}}, context(), name)

      assert Process.alive?(journal)
      assert Journal.open_groups(name) == {:ok, []}
      assert {:ok, id} = Journal.open_group(intent, context(), name)
      assert Journal.open_groups(name) == {:ok, [id]}
    end

    test "a float in an order response is recorded as a string and the order counts",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      response = %{"order_id" => "o-1", "avg_price" => 125.01, "legs" => [%{"px" => 1.0e-3}]}

      assert {:ok, _id} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: placed_entries(intent, ctx, response)},
                 name
               )

      assert %{"type" => "order", "status" => "placed", "response" => recorded} =
               List.last(records(path))

      assert recorded == %{
               "order_id" => "o-1",
               "avg_price" => "125.01",
               "legs" => [%{"px" => "0.001"}]
             }

      assert counters(name, @t0) == {{:ok, d("250")}, {:ok, 1}}
      assert Journal.verify(name) == :ok
    end

    test "a declined approval finishes the group as DENY, uncounted", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      {:ok, intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :llm)
      ctx = context()
      {:ask, _} = verdict = Policy.evaluate(intent, ctx)
      {:ok, id} = Journal.open_group(intent, ctx, name)

      :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:approval, :declined, "operator"}, name)

      assert Journal.append_to_group(id, {:placing}, name) ==
               {:error, {:unknown_or_finished_group, id}}

      assert {:error, {:invalid_entry, _}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: [{:approval, :maybe, "operator"}]},
                 name
               )

      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
    end
  end

  describe "codec" do
    test "intents and contexts round-trip through their JSON form" do
      {:ok, option} =
        Intent.option(:buy, "AAPL", d("1500.00"),
          provenance: {:untrusted, :web},
          strategy: :momentum,
          params: %{"legs" => [%{"strike" => "190"}]}
        )

      {:ok, sell} =
        Intent.sell("BRK.B", d("0.5"), provenance: {:untrusted, "email"}, strategy: "mean")

      {:ok, cancel} = Intent.cancel("o-1", provenance: :human, id: "fixed")

      for intent <- [option, sell, cancel, limit("2")] do
        json = intent |> Codec.encode_intent() |> Jason.encode!() |> Jason.decode!()
        assert Codec.decode_intent(json) == {:ok, intent}
      end

      ctx =
        context(
          positions: %{"AAPL" => d("1E+3")},
          review_warnings: ["thin market"],
          market_session: nil
        )

      json = ctx |> Codec.encode_context() |> Jason.encode!() |> Jason.decode!()
      assert Codec.decode_context(json) == {:ok, ctx}
    end

    test "floats in opaque terms become their shortest decimal strings" do
      assert Codec.term(%{"px" => 125.01, "qty" => 2, "fees" => [0.1, -3.0e-7]}) ==
               %{"px" => "125.01", "qty" => 2, "fees" => ["0.1", "-3.0e-7"]}
    end
  end
end

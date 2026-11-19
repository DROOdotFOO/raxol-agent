defmodule Raxol.Broker.Executor.ReadTest do
  @moduledoc """
  Listing consumers against the real MCP.Fake and HTTP transport, with only
  the Fake's supported scenario, on_call and inject APIs scripting pages.
  This is not live upstream pagination evidence and does not waive the
  prerelease pagination evidence gate.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.Executor.{Port, Read}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker
  alias Raxol.Broker.Tools.Catalog

  @moduletag :capture_log
  @tool "get_equity_orders"
  @args %{"account_number" => "FAKE-0001", "agent_initiated" => true, "state" => "queued"}
  @keys ["orders", "results"]
  @timeout 5_000

  setup do
    ctx = Broker.journal!()
    fake = Fake.start(page_size: 2, quotes: %{"F" => "10"})
    {:ok, port} = PortMCP.start(Fake.session(fake), mode: :dry_run)
    on_exit(fn -> Port.stop(port) end)
    {:ok, Map.merge(ctx, %{fake: fake, port: port})}
  end

  describe "listing/6" do
    test "aggregates every scenario order in order and preserves filters across cursors", ctx do
      executor = executor!(ctx)

      for number <- 1..5 do
        assert {:ok, %{status: :placed}} =
                 Executor.run(executor, intent("page-order-#{number}"), %Context{})
      end

      expected = Fake.orders(ctx.fake)
      assert length(expected) == 5
      assert listing(ctx) == {:ok, expected}

      assert listing_calls(ctx.fake) == [
               {@tool, @args},
               {@tool, Map.put(@args, "cursor", "2")},
               {@tool, Map.put(@args, "cursor", "4")}
             ]
    end

    test "follows an envelope next verbatim and retains items from every envelope", ctx do
      cursor = "https://fake.broker.test/orders?cursor=a%2Bb%3D&state=queued"
      first = [%{"order_id" => "first"}, %{"order_id" => "second"}]
      last = [%{"order_id" => "last"}]

      :ok =
        Fake.on_call(ctx.fake, @tool, fn args ->
          case Map.get(args, "cursor") do
            nil -> result(%{"data" => %{"orders" => first}, "next" => cursor})
            ^cursor -> result(%{"data" => %{"results" => last}})
          end
        end)

      assert listing(ctx) == {:ok, first ++ last}

      assert listing_calls(ctx.fake) == [
               {@tool, @args},
               {@tool, Map.put(@args, "cursor", cursor)}
             ]
    end

    test "a later transport failure returns no partial listing or absence resolution", ctx do
      executor = executor!(ctx, reconcile_min_age_ms: 0)
      :ok = Fake.inject(ctx.fake, [{"place_equity_order", {:http, 429}}])

      assert {:ok, %{group_id: group_id, status: :unknown}} =
               Executor.run(executor, intent("unknown-on-incomplete-list"), %Context{})

      assert {:ok, [%{"group_id" => ^group_id, "status" => "unknown"}] = unresolved} =
               Journal.unresolved(ctx.journal)

      before = Broker.records(ctx.path)

      :ok =
        Fake.on_call(ctx.fake, @tool, fn args ->
          refute Map.has_key?(args, "cursor")
          :ok = Fake.inject(ctx.fake, [{@tool, :closed}])
          result(%{"orders" => [%{"order_id" => "unrelated"}], "next" => "later"})
        end)

      assert listing(ctx) == {:error, {:transport, :closed}}
      assert Executor.reconcile(executor, @timeout) == {:ok, []}
      assert Journal.unresolved(ctx.journal) == {:ok, unresolved}

      assert Journal.today_notional(~U[2026-10-02 00:00:00Z], ctx.journal) ==
               {:ok, Broker.d("10")}

      assert Broker.records(ctx.path) == before
      assert Fake.orders(ctx.fake) == []

      assert for({"tools/call", @tool, status} <- Fake.requests(ctx.fake), do: status) ==
               [200, nil, 200, nil]
    end

    test "a later tool error returns an error instead of the earlier items", ctx do
      :ok =
        Fake.on_call(ctx.fake, @tool, fn args ->
          case Map.get(args, "cursor") do
            nil -> result(%{"orders" => [%{"order_id" => "first"}], "next" => "later"})
            "later" -> {:result, %{"isError" => true, "content" => []}}
          end
        end)

      assert listing(ctx) == {:error, :tool_error}

      assert listing_calls(ctx.fake) == [
               {@tool, @args},
               {@tool, Map.put(@args, "cursor", "later")}
             ]
    end

    test "an unreadable later page is not an empty terminal page", ctx do
      :ok =
        Fake.on_call(ctx.fake, @tool, fn args ->
          case Map.get(args, "cursor") do
            nil -> result(%{"orders" => [%{"order_id" => "first"}], "next" => "later"})
            "later" -> result(%{"data" => %{"orders" => nil}, "next" => "must-not-fetch"})
          end
        end)

      assert listing(ctx) == {:error, :unreadable_listing}

      assert listing_calls(ctx.fake) == [
               {@tool, @args},
               {@tool, Map.put(@args, "cursor", "later")}
             ]
    end

    test "a complete listing may finish on its twentieth page", ctx do
      :ok =
        Fake.on_call(ctx.fake, @tool, fn args ->
          number = page_number(args)
          body = %{"orders" => [%{"order_id" => "order-#{number}"}]}
          result(if number == 20, do: body, else: Map.put(body, "next", "#{number + 1}"))
        end)

      expected = Enum.map(1..20, &%{"order_id" => "order-#{&1}"})
      assert listing(ctx) == {:ok, expected}

      assert listing_calls(ctx.fake) ==
               [{@tool, @args} | Enum.map(2..20, &{@tool, Map.put(@args, "cursor", "#{&1}")})]
    end

    for continuation <- [:repeated, :advancing] do
      test "#{continuation} next stops at twenty pages without partial success", ctx do
        continuation = unquote(continuation)

        :ok =
          Fake.on_call(ctx.fake, @tool, fn args ->
            next = continuation_cursor(continuation, args)
            result(%{"orders" => [%{"order_id" => "not-a-complete-list"}], "next" => next})
          end)

        assert listing(ctx) == {:error, {:too_many_pages, @tool}}

        cursors = continuation_cursors(continuation)

        assert listing_calls(ctx.fake) ==
                 [{@tool, @args} | Enum.map(cursors, &{@tool, Map.put(@args, "cursor", &1)})]
      end
    end
  end

  defp listing(ctx),
    do: Read.listing(ctx.port, Catalog.static(), @tool, @args, @keys, @timeout)

  defp listing_calls(fake), do: for({@tool, _args} = call <- Fake.calls(fake), do: call)

  defp result(body),
    do:
      {:result,
       %{"isError" => false, "content" => [%{"type" => "text", "text" => Jason.encode!(body)}]}}

  defp page_number(args), do: args |> Map.get("cursor", "1") |> String.to_integer()

  defp continuation_cursor(:repeated, _args), do: "same"
  defp continuation_cursor(:advancing, args), do: "#{page_number(args) + 1}"
  defp continuation_cursors(:repeated), do: List.duplicate("same", 19)
  defp continuation_cursors(:advancing), do: Enum.map(2..20, &Integer.to_string/1)

  defp executor!(ctx, opts \\ []) do
    :ok = Journal.record_armed(%{"by" => "pagination-test"}, ctx.journal)
    Broker.executor!(ctx.journal, ctx.fake, opts)
  end

  defp intent(id) do
    {:ok, intent} =
      Intent.limit(:buy, "F", Broker.d("1"), Broker.d("10"), provenance: :strategy, id: id)

    intent
  end
end

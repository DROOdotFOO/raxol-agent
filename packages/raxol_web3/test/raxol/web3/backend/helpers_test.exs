defmodule Raxol.Web3.Backend.HelpersTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.Backend.Decode
  alias Raxol.Web3.Backend.Paging

  describe "Decode" do
    test "dig, field, object and rows_of read a wrong-typed value as absent" do
      body = %{"a" => %{"b" => [1]}, "s" => "text"}

      assert Decode.dig(body, ["a", "b"]) == [1]
      assert Decode.dig(body, ["s", "b"]) == nil
      assert Decode.field("not a map", "a") == nil
      assert Decode.object([1]) == %{}
      assert Decode.rows_of(%{}) == []
    end

    test "ok_or maps the reason through the mapper" do
      assert Decode.ok_or({:ok, 1}, :ref) == {:ok, 1}
      assert Decode.ok_or(:error, :ref) == {:error, :ref}

      assert Decode.ok_or(:error, "x:y", &{:unsupported_chain, &1}) ==
               {:error, {:unsupported_chain, "x:y"}}
    end

    test "int and iso8601 are lenient" do
      assert Decode.int("42") == 42
      assert Decode.int(7) == 7
      assert Decode.int("4.2") == nil
      assert Decode.int(nil) == nil
      assert %DateTime{} = Decode.iso8601("2026-09-14T10:39:37Z")
      assert Decode.iso8601("yesterday") == nil
      assert Decode.iso8601(1) == nil
    end

    test "page_rows refuses a non-list where the list belongs" do
      assert Decode.page_rows(nil) == {:ok, []}
      assert Decode.page_rows([1]) == {:ok, [1]}
      assert Decode.page_rows(%{}) == {:error, {:decode_failed, :page}}
    end

    test "json_object carries only the status of a non-2xx" do
      assert Decode.json_object({:ok, %{status: 200, body: ~s({"a":1})}}) == {:ok, %{"a" => 1}}

      assert Decode.json_object({:ok, %{status: 200, body: "[1]"}}) ==
               {:error, {:decode_failed, :not_an_object}}

      assert Decode.json_object({:ok, %{status: 200, body: "<html>"}}) ==
               {:error, {:decode_failed, :json}}

      assert Decode.json_object({:ok, %{status: 403, body: "secret page"}}) ==
               {:error, {:http, 403}}

      assert Decode.json_object({:error, :closed}) == {:error, :closed}
    end
  end

  describe "Paging" do
    test "a minted cursor round-trips only against its own origin and endpoint" do
      origin = Paging.origin_id("https://example.invalid/v0")
      other = Paging.origin_id("https://other.invalid/v0")
      cursor = Paging.next_cursor(%{"after" => 5}, origin, :canton_holdings_state)

      assert Paging.cursor_params(cursor, origin, :canton_holdings_state) ==
               {:ok, %{"after" => 5}}

      assert {:error, {:invalid_cursor, _}} =
               Paging.cursor_params(cursor, other, :canton_holdings_state)

      assert {:error, {:invalid_cursor, _}} = Paging.cursor_params(cursor, origin, :rpc_logs)
      assert Paging.cursor_params(nil, origin, :rpc_logs) == {:ok, %{}}
    end

    test "a non-map is the last page, and an unpaginated read refuses any cursor" do
      assert Paging.next_cursor(nil, "o", :rpc_logs) == nil
      assert Paging.next_cursor([1], "o", :rpc_logs) == nil
      assert Paging.no_cursor(nil) == :ok
      assert Paging.no_cursor("held") == {:error, {:invalid_cursor, :wrong_scope}}
    end
  end

  describe "Cache.opts/4" do
    test "adds a cache entry only for a classed request on a caching handle" do
      assert [cache: [key: {:k}, ttl_ms: ttl], x: 1] = Cache.opts([x: 1], true, {:k}, :catalog)
      assert is_integer(ttl)
      assert Cache.opts([x: 1], true, {:k}, nil) == [x: 1]
      assert Cache.opts([x: 1], false, {:k}, :catalog) == [x: 1]

      # Any value but `false` caches, so a stray `cache: nil` never crashes a read.
      assert [cache: _, x: 1] = Cache.opts([x: 1], nil, {:k}, :catalog)
    end
  end
end

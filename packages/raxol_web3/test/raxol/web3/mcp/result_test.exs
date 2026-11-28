defmodule Raxol.Web3.MCP.ResultTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.MCP.Result

  @address "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
  @max_safe 9_007_199_254_740_991

  defp decode!(value) do
    assert {:ok, json} = Result.encode(value)
    Jason.decode!(json)
  end

  describe "encode/1" do
    test "an integer past 2^53 is a decimal string, one inside it a number" do
      decoded = decode!(%{height: @max_safe, total: @max_safe + 1, low: -(@max_safe + 1)})

      assert decoded == %{
               "height" => @max_safe,
               "total" => "9007199254740992",
               "low" => "-9007199254740992"
             }
    end

    test "an amount is a string at every size, so one field has one JSON type" do
      decoded = decode!(%{balance: 0, value: 1, fee: 21_000, amount: 10 ** 30})

      assert decoded == %{
               "balance" => "0",
               "value" => "1",
               "fee" => "21000",
               "amount" => "1000000000000000000000000000000"
             }
    end

    test "a nil amount stays null and a string amount is untouched" do
      assert decode!(%{balance: nil, value: "0x2a"}) == %{"balance" => nil, "value" => "0x2a"}
    end

    test "a nested map: atom keys and values, tagged refs, timestamps, lists" do
      value = %{
        items: [
          %{
            token: %{address: "0xabc", decimals: 18, symbol: nil},
            amount: 2 ** 64,
            from: {:evm, @address},
            status: :success,
            timestamp: ~U[2026-11-28 12:00:00Z],
            indexer: %{finished?: true, indexed_ratio: 1.0}
          }
        ],
        next: nil
      }

      assert decode!(value) == %{
               "items" => [
                 %{
                   "token" => %{"address" => "0xabc", "decimals" => 18, "symbol" => nil},
                   "amount" => "18446744073709551616",
                   "from" => "evm:#{@address}",
                   "status" => "success",
                   "timestamp" => "2026-11-28T12:00:00Z",
                   "indexer" => %{"finished?" => true, "indexed_ratio" => 1.0}
                 }
               ],
               "next" => nil
             }
    end

    test "upstream JSON under string keys is passed through as the upstream wrote it" do
      # A contract ABI is upstream JSON: its "value" is not one of our amounts.
      abi = [%{"type" => "function", "name" => "f", "value" => 5}]

      assert decode!(%{abi: abi, verified?: true}) == %{"abi" => abi, "verified?" => true}
    end

    test "an integer past 2^53 under a string key is a decimal string too" do
      abi = [%{"type" => "constant", "value" => @max_safe + 1, "small" => @max_safe}]

      assert decode!(%{abi: abi}) == %{
               "abi" => [
                 %{"type" => "constant", "value" => "9007199254740992", "small" => @max_safe}
               ]
             }
    end

    test "a value JSON cannot hold is a closed error, not a raise" do
      assert Result.encode(%{data: <<0xFF, 0xFE>>}) == {:error, :unencodable_result}
    end
  end
end

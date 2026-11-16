defmodule Raxol.Payments.Ramp.ConformanceTest do
  use ExUnit.Case, async: true
  alias Raxol.Payments.Ramp
  @fixture Path.expand("../../../fixtures/ramp/conformance.json", __DIR__)
  @vectors @fixture |> File.read!() |> Jason.decode!()

  for vector <- @vectors["wire_cases"] do
    @vector vector
    test "wire: #{vector["id"]}" do
      result = Ramp.decode(@vector["input"])
      assert match?({:ok, _}, result) == @vector["valid"]

      if @vector["valid"] do
        {:ok, message} = result
        {:ok, encoded} = Ramp.encode(message)
        assert Ramp.decode(Jason.decode!(encoded)) == result

        if @vector["input"]["kind"] == "snapshot" do
          assert Ramp.Coherence.terminal?(Ramp.to_wire(message)) == @vector["input"]["terminal"]
        end
      end
    end
  end

  for {vector, i} <- Enum.with_index(@vectors["atomic_cases"]) do
    @vector vector
    test "atomic: #{i}" do
      assert Ramp.atomic?(@vector["value"]) == @vector["valid"]
    end
  end

  for vector <- @vectors["command_cases"] do
    @vector vector
    test "command: #{vector["id"]}" do
      assert Ramp.CommandCheck.check(@vector["snapshot"], @vector["command"], @vector["receipt"])
             |> Atom.to_string() == @vector["expected"]
    end
  end

  test "unknown optional fields are bounded and stripped recursively" do
    offer = hd(@vectors["wire_cases"])["input"]
    {:ok, base} = Ramp.decode(offer)
    {:ok, extended} = Ramp.decode(Map.put(offer, "future_optional", %{"value" => "synthetic"}))
    assert extended == base

    assert {:error, :invalid_request} =
             Ramp.decode(Map.put(offer, "large", String.duplicate("a", 2049)))

    assert {:error, :invalid_request} =
             Ramp.decode(Map.put(offer, "array", List.duplicate(nil, 129)))

    assert {:error, :invalid_request} =
             Ramp.decode(Map.put(offer, "utf16", String.duplicate("😀", 1025)))

    nested = Enum.reduce(1..17, nil, fn _, acc -> [acc] end)
    assert {:error, :invalid_request} = Ramp.decode(Map.put(offer, "nested", nested))
  end

  test "runtime schema is identical to canonical artifact" do
    canonical = Path.expand("../../../fixtures/ramp/contract.schema.json", __DIR__)

    assert File.read!(canonical) ==
             File.read!(Application.app_dir(:raxol_payments, "priv/ramp/contract.schema.json"))
  end
end

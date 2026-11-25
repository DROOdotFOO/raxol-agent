defmodule Raxol.Payments.Directive.PayTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Directive.Executor
  alias Raxol.Payments.Directive.Pay

  describe "new/1" do
    test "builds a Pay with required fields" do
      pay =
        Pay.new(
          amount: Decimal.new("0.01"),
          domain: "api.test.com",
          perform: fn -> {:ok, :done} end
        )

      assert %Pay{
               amount: %Decimal{},
               domain: "api.test.com",
               agent_id: nil,
               meta: %{},
               perform: perform
             } = pay

      assert is_function(perform, 0)
    end

    test "carries optional fields" do
      pay =
        Pay.new(
          amount: Decimal.new("1.00"),
          domain: "api.test.com",
          agent_id: :research,
          meta: %{tag: "experiment"},
          perform: fn -> {:ok, :done} end
        )

      assert pay.agent_id == :research
      assert pay.meta == %{tag: "experiment"}
    end

    test "raises without required fields" do
      assert_raise KeyError, fn ->
        Pay.new(domain: "x", perform: fn -> {:ok, :done} end)
      end
    end
  end

  describe "Executor for Pay" do
    test "successful perform sends pay_result" do
      assert execute(fn -> {:ok, %{ok: true}} end) == {:pay_result, %{ok: true}}
    end

    test "error perform sends pay_error" do
      assert execute(fn -> {:error, :insufficient_funds} end) ==
               {:pay_error, :insufficient_funds}
    end

    test "raised exception sends pay_error with exception tag" do
      assert execute(fn -> raise "wallet locked" end) ==
               {:pay_error, {:exception, "wallet locked"}}
    end

    test "non-tuple return is treated as pay_result" do
      assert execute(fn -> :raw_value end) == {:pay_result, :raw_value}
    end
  end

  # Run `perform` through the executor and return the `{:command_result, _}`
  # payload it sends. `perform` runs in a process the executor starts; it
  # reports itself first, so the wait is for that process's result or its
  # exit, with no clock.
  defp execute(perform) do
    test = self()

    pay =
      Pay.new(
        amount: Decimal.new("0.01"),
        domain: "x.com",
        perform: fn ->
          send(test, {:performing, self()})
          perform.()
        end
      )

    Executor.execute(pay, %{pid: test, runtime_pid: test})
    worker = receive(do: ({:performing, pid} -> pid))
    ref = Process.monitor(worker)

    receive do
      {:command_result, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^worker, reason} ->
        flunk("the perform process exited (#{inspect(reason)}) without a result")
    end
  end
end

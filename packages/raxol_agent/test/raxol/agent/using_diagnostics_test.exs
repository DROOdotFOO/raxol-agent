defmodule Raxol.Agent.UsingDiagnosticsTest do
  use ExUnit.Case, async: true

  defp compile(source) do
    {[{module, _binary}], diagnostics} =
      Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    {module, diagnostics}
  end

  test "a module with only `use Raxol.Agent` compiles with no diagnostics" do
    source = """
    defmodule Raxol.Agent.UsingDiagnosticsTest.DefaultAgent do
      use Raxol.Agent
    end
    """

    assert {agent, []} = compile(source)
    assert agent.available_actions() == []
  end

  test "overriding skills_provider/0 compiles with no diagnostics and exposes skill actions" do
    source = """
    defmodule Raxol.Agent.UsingDiagnosticsTest.SkilledAgent do
      use Raxol.Agent

      def skills_provider, do: Raxol.Agent.Skills.Store
    end
    """

    assert {agent, []} = compile(source)
    assert agent.available_actions() == Raxol.Agent.Actions.Skills.actions()
  end
end

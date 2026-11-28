defmodule Raxol.Payments.ExamplesTest do
  # Runs the offline examples the way `examples/README.md` tells a new user
  # to, as their own `mix run`: each script halts the VM when a step fails.
  use ExUnit.Case, async: true

  @package_root Path.expand("../../..", __DIR__)
  @offline_examples [
    "examples/agent_payment_tour.exs",
    "examples/privacy_modes.exs",
    "examples/crosschain_stealth_payment.exs"
  ]

  @moduletag timeout: :timer.minutes(5)

  for example <- @offline_examples do
    test "#{example} runs offline and exits 0" do
      {output, status} = run_example(unquote(example))

      assert status == 0, "#{unquote(example)} exited #{status}:\n\n#{output}"
    end
  end

  defp run_example(example) do
    System.cmd(System.find_executable("mix"), ["run", example],
      cd: @package_root,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end

defmodule Raxol.CLI do
  @moduledoc """
  Argv dispatcher for the `raxol` command.

  Bare `raxol` prints the help; the subcommands expose the Raxol toolkit. The
  release entrypoint (`Raxol.CLI.Application`) reads the Burrito-wrapped argv
  and calls `main/1`, which returns the process exit code.
  """

  @commands ~w(acp mcp doctor update playground new help)

  @doc """
  Dispatch `argv`, returning an exit code.

  A VM booted for `raxol mcp` (`config/runtime.exs`, e.g. `RAXOL_MODE=mcp`
  left exported) runs nothing else: its stray output goes to stderr and its
  apps start in MCP mode, so any other command is refused with exit 1.
  """
  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    if Application.get_env(:raxol_cli, :mcp_boot, false) and not match?(["mcp" | _], argv) do
      IO.puts(:stderr, "raxol: this VM booted for `raxol mcp` (RAXOL_MODE=mcp?); only mcp runs")
      1
    else
      dispatch(argv)
    end
  end

  defp dispatch([]), do: help()
  # Serve a Raxol agent over ACP on stdio, for editors that spawn us.
  defp dispatch(["acp" | rest]), do: Raxol.Agent.ClientProtocol.Serve.run(rest)
  # Serve Raxol apps as MCP tools on stdio, for OMP and other MCP clients.
  defp dispatch(["mcp" | rest]), do: Raxol.CLI.MCP.run(rest)
  defp dispatch(["doctor" | rest]), do: Raxol.CLI.Doctor.run(rest)

  defp dispatch(["update" | rest]), do: Raxol.CLI.Update.run(rest)
  defp dispatch(["playground" | _rest]), do: run_playground()
  defp dispatch(["new" | rest]), do: Raxol.CLI.New.run(rest)

  defp dispatch(["--version"]) do
    IO.puts("raxol #{version()}")
    0
  end

  defp dispatch([help]) when help in ~w(help --help -h), do: help()

  defp dispatch([unknown | _]) do
    IO.puts(:stderr, "raxol: unknown command #{inspect(unknown)}\n")
    help()
    1
  end

  # The component-catalog TUI. Over a pipe it exits with a message, not a crash.
  defp run_playground do
    cond do
      !interactive?() ->
        IO.puts(:stderr, "raxol playground requires an interactive terminal.")
        1

      auto_update_prompt() == :updated ->
        0

      true ->
        {:ok, _pid} = Raxol.start_link(Raxol.Playground.App, mouse: false)

        receive do
          :playground_done -> :ok
        end

        0
    end
  end

  defp auto_update_prompt do
    Raxol.CLI.Update.auto_prompt(prompt?: interactive?(false))
  end

  # Whether a full-screen TUI has a terminal to draw on. Burrito's launcher
  # puts stdout on a pipe, so under it `:io.getopts()` reports no terminal
  # on every run; there the inherited stdin answers (termbox2 opens
  # /dev/tty itself). Elsewhere the group leader answers, which is what
  # `with_io/1` swaps in tests.
  defp interactive?, do: interactive?(burrito?())

  @doc false
  # Public so a test can pin each branch.
  @spec interactive?(boolean()) :: boolean()
  def interactive?(true), do: tty_stdin?()
  def interactive?(false), do: terminal_group_leader?()

  defp burrito?, do: System.get_env("__BURRITO") == "1"

  defp terminal_group_leader? do
    case :io.getopts() do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) != false
      _ -> false
    end
  rescue
    _ -> false
  end

  defp tty_stdin? do
    Code.ensure_loaded?(:prim_tty) and
      function_exported?(:prim_tty, :isatty, 1) and
      :prim_tty.isatty(:stdin) == true
  rescue
    _ -> false
  end

  defp help do
    IO.puts(banner())

    IO.puts("""

    Usage: raxol [command]

    Commands:
      acp           Serve a Raxol agent over the Agent Client Protocol (--agent)
      mcp           Serve Raxol apps as MCP tools on stdio (for OMP)
      doctor        Report this install: build, runtime, ACP surface
      update        Update the installed binary from GitHub Releases
      playground    Browse the interactive component catalog
      new [name]    Scaffold an Elixir/Mix Raxol application
      help          Show this help

    Options:
      --version     Show the installed Raxol version
      -h, --help    Show this help
    """)

    0
  end

  defp banner, do: "raxol #{version()} -- TUI toolkit and agent runtime"

  # The commit this binary was built from, baked in at compile time so two
  # builds of the same release version can be told apart. `@external_resource`
  # on `.git/HEAD` recompiles this module when the commit moves.
  @git_head Path.join([__DIR__, "..", "..", "..", "..", ".git", "HEAD"])
  if File.exists?(@git_head), do: @external_resource(@git_head)

  @build_sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
                {sha, 0} -> String.trim(sha)
                _ -> nil
              end)

  @doc false
  # Public so `Raxol.CLI.Doctor` reports the same string the banner does.
  @spec version() :: String.t()
  def version do
    case :application.get_key(:raxol_cli, :vsn) do
      {:ok, vsn} -> stamped(List.to_string(vsn))
      _ -> stamped("dev")
    end
  end

  # Without git (a Hex install, a source tarball) the version is bare. Chosen
  # at compile time: a runtime guard on the constant would leave a dead clause.
  if is_binary(@build_sha) do
    defp stamped(vsn), do: vsn <> "+" <> @build_sha
  else
    defp stamped(vsn), do: vsn
  end

  @doc false
  @spec commands() :: [String.t()]
  def commands, do: @commands
end

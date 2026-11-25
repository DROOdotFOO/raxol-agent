defmodule Raxol.Console.Application do
  @moduledoc """
  Container entrypoint for a Raxol Console runtime.

  Started as the OTP application callback (`mod:`) outside `:test`. It reads the
  materialized agent package plus the deployment environment, builds a
  `Raxol.Console.RuntimeConfig`, and boots via `Raxol.Console.Boot`. With nothing
  configured it starts an empty supervisor, so depending on `raxol_console` never
  self-boots a runtime.

  ## Configuration

  The package is a directory of the generator's output (`soul.md`, `AGENTS.md`,
  `tasks.json`, `skills/`, `manifest.json`), located by `:package_dir` or
  `RAXOL_CONSOLE_PACKAGE`:

      config :raxol_console,
        package_dir: "/srv/agent",
        channels: [%{platform: :telegram, adapter: MyAdapter, config: %{...}}],
        agent_opts: [backend: MyBackend, backend_opts: [...]],
        default_target: "telegram:home",
        workspace: "/srv/agent/workspace",
        bundle_default_mcp: true

  ## Who may talk to this agent

  With no `:pairing` key every inbound chat is DENIED, and the boot warns and
  emits `[:raxol_console, :pairing, :undeclared]`. Choose one:

      pairing: [allow_platforms: [:telegram]]           # anyone on Telegram
      pairing: [allowed_users: ["12345"]]               # these ids, any platform
      pairing: [platform_users: [telegram: ["12345"]]]  # these ids, there
      pairing: :open                                    # everyone, explicitly
      pairing: []                                       # deny all; pair by hand

  The allowlist decides who may OPEN a chat, not who reads replies: an allowed
  user who adds the bot to a group exposes its output there, so prefer
  `chat_type: :dm` channels for an agent with credentials. `:allowed_users` and
  confirmed pairings match on id alone, across platforms. There is no `/pair`
  command; pair newcomers out of band (see `Raxol.Console.Inbound`). Inbound
  events are gated by `Raxol.Console.Inbound.route/3` and by the router itself.

  ## Per-chat apps

  A chat turn runs the stateless agent loop by default. To run a TEA app per chat,
  name a template registered in `Raxol.Console.AppRegistry`:

      config :raxol_console, :app_templates, %{"dashboard" => MyConsole.Dashboard}
      config :raxol_console,
        handler_mode: :app, app_template: "dashboard",
        idle_timeout: :timer.hours(6), max_sessions: 200

  Pick `:max_sessions` for the `:idle_timeout` (see `RuntimeConfig.build/2`).
  Credentials, channels and inference are deployment-owned and arrive through
  `:agent_opts`, `:channels` and the payments config. There is no web server or
  health endpoint. A configured-but-invalid package fails the boot with
  `{:error, reason}`.
  """

  use Application
  require Logger

  alias Raxol.Earn.Console.Package
  alias Raxol.Console.{Boot, RuntimeConfig}

  # Every deployment option `RuntimeConfig.build/2` understands. Both takes below
  # filter through this list, so a key missing here is silently dropped on the
  # way in and its feature is unreachable from application config.
  @rc_keys [
    :channels,
    :agent_opts,
    :default_target,
    :workspace,
    :bundle_default_mcp,
    :handler_mode,
    :app_template,
    :idle_timeout,
    :max_sessions,
    :pairing
  ]

  @impl true
  def start(_type, _args) do
    case plan(Application.get_all_env(:raxol_console)) do
      :none ->
        empty_supervisor()

      {:ok, dir, opts} ->
        dir |> boot(opts) |> to_app_result()
    end
  end

  @doc false
  # Pure: decide whether a runtime is configured and assemble its boot options.
  # `:none` when no package is located; `{:ok, dir, opts}` otherwise.
  @spec plan(keyword()) :: :none | {:ok, Path.t(), keyword()}
  def plan(config) do
    case package_dir(config) do
      nil -> :none
      dir -> {:ok, dir, boot_opts(config)}
    end
  end

  @doc false
  # Load the package, build its runtime config, and boot the tree. Returns the
  # boot report so the caller can log it (and the supervisor pid to own).
  @spec boot(Path.t(), keyword()) :: {:ok, Boot.report()} | {:error, term()}
  def boot(dir, opts) do
    with {:ok, pkg} <- load(dir),
         {:ok, rc} <- build(pkg, opts) do
      boot_opts =
        opts
        |> Keyword.take([:actions])
        |> Keyword.put(:skills_dir, Path.join(dir, "skills"))

      Boot.start(rc, boot_opts)
    end
  end

  defp package_dir(config) do
    case Keyword.get(config, :package_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.get_env("RAXOL_CONSOLE_PACKAGE")
    end
  end

  defp boot_opts(config) do
    config
    |> Keyword.take([:actions | @rc_keys])
    |> Keyword.put_new(:channels, [])
    |> Keyword.put_new(:agent_opts, [])
  end

  defp load(dir) do
    case Package.load(dir) do
      {:ok, pkg} -> {:ok, pkg}
      {:error, reason} -> {:error, {:package_load_failed, reason}}
    end
  end

  defp build(pkg, opts) do
    case RuntimeConfig.build(pkg, Keyword.take(opts, @rc_keys)) do
      {:ok, rc} -> {:ok, rc}
      {:error, reason} -> {:error, {:runtime_config_failed, reason}}
    end
  end

  defp to_app_result({:ok, report}) do
    Logger.info(
      # The posture belongs on the line an operator actually reads. The boot
      # warning fires once and is easy to lose in container startup noise,
      # which left "open to everyone" visible nowhere at a glance.
      "[Raxol.Console] booted: " <>
        "jobs created=#{length(report.jobs.created)} updated=#{length(report.jobs.updated)} " <>
        "removed=#{length(report.jobs.removed)} failed=#{length(report.jobs.failed)}, " <>
        "mcp tools=#{report.mcp.tools}, skills=#{report.skills.count}, " <>
        "channels=#{inspect(report.channels)}, pairing=#{report.pairing}"
    )

    {:ok, report.supervisor}
  end

  defp to_app_result({:error, reason} = error) do
    Logger.error("[Raxol.Console] boot failed: #{inspect(reason)}")
    error
  end

  defp empty_supervisor do
    Supervisor.start_link([],
      strategy: :one_for_one,
      name: Raxol.Console.Application.RootSupervisor
    )
  end
end

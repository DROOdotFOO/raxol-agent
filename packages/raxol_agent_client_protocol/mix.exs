defmodule RaxolAgentClientProtocol.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/DROOdotFOO/raxol-agent"
  @source_ref "raxol_agent_client_protocol-v#{@version}"

  def project do
    [
      app: :raxol_agent_client_protocol,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Agent Client Protocol",
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :underspecs],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      # The package's shared supervision tree (SessionRegistry, journal Writer
      # supervisor/registry, attach-policy Task.Supervisor, standalone
      # ConnectionsSupervisor). `RaxolAgentClientProtocol.Application` starts an
      # EMPTY tree under MIX_ENV=test (compile-time `@auto_start` guard) so the
      # existing suite's manually/injected supervisors never collide.
      mod: {RaxolAgentClientProtocol.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      # `Raxol.Core.ChildEnv`, the credential scrub `Transport.Stdio` applies to
      # a spawned agent, shared with the rest of raxol. `runtime: false`: this
      # package only calls that one module, which needs no application state,
      # so a host does not start raxol_core (or the `:mnesia` its `.app`
      # lists). A host that builds a release must ship the code: see the
      # README's "Releases" note.
      {:raxol_core, "~> 2.9", runtime: false},

      # Dev/test only
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_json_schema, "~> 0.10", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Hex rejects a description over 300 characters. The resumable-session
  # vendor extension is documented in the README rather than here.
  defp description do
    """
    Elixir/OTP implementation of ACP (Agent Client Protocol) — the JSON-RPC 2.0
    protocol between code editors and AI coding agents (agentclientprotocol.com).
    Bidirectional agent/client roles, stdio and in-process transports,
    supervised session processes, and resumable sessions (in-memory journal).
    """
  end

  defp package do
    [
      name: "raxol_agent_client_protocol",
      # NOTE: priv/schema-oracle is deliberately EXCLUDED — the official ACP
      # JSON Schema is an Apache-2.0 dev/test oracle and is never shipped.
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md NOTICE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "ACP spec" => "https://agentclientprotocol.com",
        "Docs" => "https://hexdocs.pm/raxol_agent_client_protocol",
        "Changelog" =>
          "#{@source_url}/blob/main/packages/raxol_agent_client_protocol/CHANGELOG.md"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: @source_ref,
      # The package lives under packages/raxol_agent_client_protocol in its repository.
      source_url_pattern:
        "#{@source_url}/blob/#{@source_ref}/packages/raxol_agent_client_protocol/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md", "NOTICE.md"]
    ]
  end
end

defmodule RaxolAgent.MixProject do
  use Mix.Project

  @version "3.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol-agent"
  @source_ref "raxol_agent-v#{@version}"

  def project do
    [
      app: :raxol_agent,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Agent",
      source_url: @source_url,
      homepage_url: "https://raxol.io"
    ]
  end

  def application do
    app = [extra_applications: [:logger]]

    if Mix.env() != :test do
      Keyword.put(app, :mod, {RaxolAgent.Application, []})
    else
      app
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      runtime_dep(:raxol, "~> 2.8", "."),
      runtime_dep(:raxol_mcp, "~> 2.8", "packages/raxol_mcp"),
      runtime_dep(:raxol_journal, "~> 2.8", "packages/raxol_journal"),
      {:circular_buffer, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      # Floor: CVE-2026-49755 (unbounded decompression), fixed in 0.6.1.
      {:req, "~> 0.6 and >= 0.6.1", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      # Lets the :integration ThreadLog.Postgrex suite run; the adapter
      # itself leaves the driver to the host app.
      {:postgrex, "~> 0.22.0", only: :test}
    ] ++ acp_dep() ++ web3_dep()
  end

  # raxol_agent_client_protocol is a required dependency in every form:
  # `Raxol.Agent.ClientProtocol.StdioAgent` and the rest of the ACP agent are
  # compile-gated on the package's presence, and a dep edge is what orders the
  # ACP package's compilation ahead of the gate that tests for it. The Hex form
  # (HEX_BUILD, or inside a Hex install) requires the published package; a
  # source build takes the sibling directory, in EVERY env, not just dev/test:
  # the packaged `raxol acp` is a :prod build of this package.
  defp acp_dep do
    path = "../raxol_agent_client_protocol"

    if hex_package?() do
      [{:raxol_agent_client_protocol, "~> 0.1"}]
    else
      [{:raxol_agent_client_protocol, path: path, override: true}]
    end
  end

  # `raxol_web3` is unpublished, so naming it in the Hex package would make
  # raxol_agent unpublishable. HEX_BUILD therefore drops it entirely, and a
  # Hex install has no `web3` tool (`Raxol.Agent.Actions.Web3` is
  # compile-gated on the package's presence).
  #
  # The edge points this way, from consumer to provider, and that is the whole
  # reason the tool lives here rather than in `raxol_web3`. ADR-0033 decision 2
  # places that package BELOW `raxol_payments` precisely so a read layer does
  # not depend on the agent runtime; a `Raxol.Agent.Action` defined over there
  # would need `use Raxol.Agent.Action`, which would pull the framework and the
  # agent runtime underneath a read-only package and invert the graph the ADR
  # exists to fix.
  defp web3_dep do
    path = "../raxol_web3"

    if hex_package?() do
      []
    else
      [{:raxol_web3, path: path, override: true}]
    end
  end

  # A runtime package: its Hex release, or a checkout of the runtime
  # repository when RAXOL_PATH names one (absolute, or relative to this
  # repository's root).
  defp runtime_dep(name, version, subdir, opts \\ []) do
    checkout = System.get_env("RAXOL_PATH", "")

    if hex_package?() or checkout == "" do
      {name, version, opts}
    else
      root = Path.expand(checkout, Path.expand("../..", __DIR__))
      {name, version, [path: Path.expand(subdir, root), override: true] ++ opts}
    end
  end

  # Hex form for a publish (HEX_BUILD=1) and inside a Hex install, which Hex
  # marks by unpacking hex_metadata.config beside mix.exs; a path dep anywhere
  # else, whether or not the directory exists. A dependency updater resolves in
  # a sandbox holding only mix.exs and mix.lock, and reading that absence as a
  # Hex install would lock the siblings as Hex packages. A directory check
  # would also make `../..` a path dep inside a consumer's deps/: a parent
  # always exists.
  defp hex_package? do
    System.get_env("HEX_BUILD") != nil or File.exists?("hex_metadata.config")
  end

  defp description do
    """
    AI agent framework for Elixir built on OTP. TEA-based agents with crash
    isolation, inter-agent messaging, team supervision, and real SSE streaming
    to Anthropic, OpenAI, Ollama, and more.
    """
  end

  defp package do
    [
      name: "raxol_agent",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_agent",
        "Changelog" => "#{@source_url}/blob/main/packages/raxol_agent/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: @source_ref,
      # The package lives under packages/raxol_agent in its repository.
      source_url_pattern:
        "#{@source_url}/blob/#{@source_ref}/packages/raxol_agent/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"],
      # The changelog names functions this release removes.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end

defmodule RaxolBroker.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol-agent"
  @source_ref "raxol_broker-v#{@version}"

  def project do
    [
      app: :raxol_broker,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Broker",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol_agent, "~> 3.0", "../raxol_agent", []),
      runtime_dep(:raxol_journal, "~> 2.8", "packages/raxol_journal"),
      runtime_dep(:raxol_mcp, "~> 2.8", "packages/raxol_mcp"),
      # `Raxol.Broker.Dashboard` is a TEA app: the runtime, LiveView and SSH
      # surfaces it mounts on.
      runtime_dep(:raxol, "~> 2.8", "."),
      # Floor: below 3.1.2, `Decimal.round/3` allocates in proportion to
      # `places` (CVE-2026-97853).
      {:decimal, "~> 3.1 and >= 3.1.2"},
      # The daily cap resets at midnight America/New_York; Elixir ships no
      # time zone database. Passed explicitly, never set as the VM default.
      {:tz, "~> 0.28.4"},
      # The Robinhood MCP endpoint is remote: `Raxol.MCP.Client.Transport.Http`
      # compiles only with mint, and the OAuth discovery, registration and
      # token calls default to Req. Both are optional upstream.
      {:mint, "~> 1.8"},
      {:castore, "~> 1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # `Raxol.Broker.MCP.Fake` is built on raxol_mcp's reference server,
      # which compiles only with plug (optional upstream).
      {:plug, "~> 1.16"},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp raxol_dep(name, version, path, opts) do
    if hex_package?() do
      {name, version, opts}
    else
      {name, version, [path: path] ++ opts}
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
  # else, whether or not the directory exists. Dependabot resolves a bump in a
  # sandbox holding only mix.exs and mix.lock, and reading that absence as a
  # Hex install locked the siblings as Hex packages, which
  # scripts/check_lock_path_shadows.exs rejects.
  defp hex_package? do
    System.get_env("HEX_BUILD") != nil or File.exists?("hex_metadata.config")
  end

  defp description do
    "Guarded Robinhood order execution for Raxol: fail-closed policy, mandatory review, " <>
      "explicit arming, a hash-chained journal and a kill switch."
  end

  defp package do
    [
      name: "raxol_broker",
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_broker",
        "Changelog" => "#{@source_url}/blob/main/packages/raxol_broker/CHANGELOG.md",
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
      # The package lives under packages/raxol_broker in its repository.
      source_url_pattern:
        "#{@source_url}/blob/#{@source_ref}/packages/raxol_broker/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
    ]
  end
end

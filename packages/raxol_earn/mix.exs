defmodule RaxolEarn.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/DROOdotFOO/raxol-agent"
  @source_ref "raxol_earn-v#{@version}"

  def project do
    [
      app: :raxol_earn,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      dialyzer: [
        # raxol_agent reaches this app through raxol_payments, where it is
        # `runtime: false`, so it is not in the derived application tree.
        # Earn calls it directly (`Raxol.Agent.Secret`, `Raxol.Agent.ChildEnv`).
        plt_add_apps: [:raxol_agent],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Earn",
      source_url: @source_url
    ]
  end

  def application do
    app = [extra_applications: [:logger, :crypto]]

    if Mix.env() != :test do
      Keyword.put(app, :mod, {RaxolEarn.Application, []})
    else
      app
    end
  end

  # Slim headless release for the settlement-accounting sidecar and solver.
  # Starts :raxol_earn + its runtime deps (:raxol_payments, :raxol_core,
  # :raxol_web3, :raxol_mcp, req, cowboy, the crypto NIFs). raxol_payments calls
  # raxol_agent code at run time, so the agent side ships as well -- :raxol_agent
  # and the runtime apps it requires, :raxol_terminal (with its termbox NIF)
  # included -- but only LOADED: nothing here needs the agent supervisor, the
  # raxol application or the terminal, so none of them starts. Mix allows :load
  # only because no started application depends on them: raxol_payments takes
  # raxol_agent with `runtime: false`. Build with
  # `MIX_ENV=prod mix release raxol_earn` from this package.
  defp releases do
    [
      raxol_earn: [
        include_executables_for: [:unix],
        steps: [:assemble],
        # runtime_tools makes :observer/:recon remote diagnostics available without
        # starting anything at boot; the agent side is loaded, not started (above).
        applications: [
          runtime_tools: :load,
          raxol_agent: :load,
          raxol: :load,
          raxol_terminal: :load,
          raxol_journal: :load
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol_payments, "~> 0.3", "../raxol_payments", []),
      runtime_dep(:raxol_core, "~> 2.8", "packages/raxol_core"),
      runtime_dep(:raxol_mcp, "~> 2.8", "packages/raxol_mcp", runtime: false),
      {:req, "~> 0.5"},
      {:ex_keccak, "~> 0.7"},
      {:jason, "~> 1.4"},
      # Floor: CVE-2026-97853 (`Decimal.round/3`), fixed in 3.1.2.
      {:decimal, "~> 3.1 and >= 3.1.2"},
      {:mint_web_socket, "~> 1.0"},
      {:cowboy, "~> 2.10"},
      {:stream_data, "~> 1.0", only: :test},
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
    """
    Elixir/OTP-native Agent Commerce Protocol (ACP) implementation for the
    Virtuals agent marketplace. One supervised process per active job, EIP-712
    signing via raxol_payments, and offerings declared as raxol widgets.
    """
  end

  defp package do
    [
      name: "raxol_earn",
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_earn",
        "Changelog" => "#{@source_url}/blob/main/packages/raxol_earn/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  # Package-scoped tag, not `v#{@version}`: the bare `vX.Y.Z` tags belong to
  # the root `raxol` version line, and `v0.2.0` there is raxol from 2025. A
  # bare tag would point every source link in these docs at unrelated code.
  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: @source_ref,
      # The package lives under packages/raxol_earn in its repository.
      source_url_pattern:
        "#{@source_url}/blob/#{@source_ref}/packages/raxol_earn/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

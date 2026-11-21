defmodule RaxolPayments.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/DROOdotFOO/raxol-agent"
  @source_ref "raxol_payments-v#{@version}"

  def project do
    [
      app: :raxol_payments,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        # In this repository raxol_agent is runtime: false (see deps/0), so it
        # is not in the application tree dialyzer derives (the Hex form drops
        # the flag). Add it (with :mix, for the Mix.Task callbacks) to the PLT
        # so the Action behaviour, CommandHook and Mix.Task callbacks resolve.
        plt_add_apps: [:raxol_agent, :mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Payments",
      source_url: @source_url,
      homepage_url: "https://raxol.io"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Payments calls raxol_agent code at run time (`Raxol.Agent.Action`,
      # `Raxol.Agent.ContextStore`). In-repo, `runtime: false` keeps
      # :raxol_agent out of this application's start list, so the raxol_earn
      # release ships the agent modules loaded without starting the agent
      # tree. `raxol_dep/4` drops it from the Hex form: a consumer compiles
      # this mix.exs, and the flag would leave raxol_agent out of its release.
      raxol_dep(:raxol_agent, "~> 3.2", "../raxol_agent", runtime: false),
      # Raxol.Core.Stores.Dets/Naming back Raxol.Payments.Mandate.Store
      runtime_dep(:raxol_core, "~> 2.8", "packages/raxol_core"),
      # Floor: CVE-2026-49755 (unbounded decompression), fixed in 0.6.1.
      {:req, "~> 0.6 and >= 0.6.1"},
      {:ex_secp256k1, "~> 0.8"},
      {:ex_keccak, "~> 0.7"},
      {:jason, "~> 1.4"},
      # Floor: CVE-2026-97853 (`Decimal.round/3`), fixed in 3.1.2.
      {:decimal, "~> 3.1 and >= 3.1.2"},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      # Optional: only needed when running EchoServer (`mix raxol_payments.echo`).
      # Floors: plug CVE-2026-54892 (quadratic parameter decoding), fixed in
      # 1.19.3 on the 1.19 line; plug_cowboy CVE-2026-32688 (HTTP/2 atom
      # exhaustion), fixed in 2.8.1.
      {:plug, "~> 1.19 and >= 1.19.3", optional: true},
      {:plug_cowboy, "~> 2.8 and >= 2.8.1", optional: true}
    ] ++ web3_dep()
  end

  # Optional, and absent from a Hex build: raxol_web3 is unpublished, so naming
  # it would make this package unpublishable (the raxol_agent `web3_dep/0`
  # precedent). It backs `Raxol.Payments.Prices.FX`; `Accounting` refuses
  # `RAXOL_FX_ENABLED=true` in a build without it (ADR-0040 decision 6).
  defp web3_dep do
    path = "../raxol_web3"

    if hex_package?() do
      []
    else
      [{:raxol_web3, path: path, override: true, optional: true}]
    end
  end

  defp raxol_dep(name, version, path, opts) do
    if hex_package?() do
      {name, version, Keyword.delete(opts, :runtime)}
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
  # else, whether or not the directory exists. A dependency updater resolves in
  # a sandbox holding only mix.exs and mix.lock, and reading that absence as a
  # Hex install would lock the siblings as Hex packages.
  defp hex_package? do
    System.get_env("HEX_BUILD") != nil or File.exists?("hex_metadata.config")
  end

  defp description do
    """
    Autonomous payment capabilities for Raxol agents. Xochi cross-chain
    intent settlement, x402/MPP auto-pay, wallet management, and spending controls.
    """
  end

  defp package do
    [
      name: "raxol_payments",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_payments",
        "Changelog" => "#{@source_url}/blob/main/packages/raxol_payments/CHANGELOG.md",
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
      # The package lives under packages/raxol_payments in its repository.
      source_url_pattern:
        "#{@source_url}/blob/#{@source_ref}/packages/raxol_payments/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

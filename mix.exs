defmodule QuackDB.MixProject do
  use Mix.Project

  def project do
    [
      app: :quackdb,
      version: "0.5.3",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      description: "Remote DuckDB Quack protocol client for Elixir",
      source_url: "https://github.com/elixir-vibe/quackdb",
      homepage_url: "https://github.com/elixir-vibe/quackdb",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {QuackDB.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:db_connection, "~> 2.7"},
      {:mint, "~> 1.8"},
      {:castore, "~> 1.0"},
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:muontrap, "~> 1.5"},
      {:telemetry, "~> 1.0"},
      {:varint, "~> 1.6"},
      {:table, "~> 0.1", optional: true},
      {:ecto_sql, "~> 3.13", optional: true},
      {:explorer, "~> 0.11", optional: true},
      {:geo, "~> 4.1", optional: true},
      {:fsst, "~> 0.1.2", optional: true},
      {:stream_data, "~> 1.2", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:libgraph, "~> 0.16", only: [:dev, :test], runtime: false},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "ex_dna --max-clones 0",
        "reach.check --smells --strict"
      ]
    ]
  end

  defp package do
    [
      files:
        ~w(.formatter.exs CHANGELOG.md CONTRIBUTING.md README.md docs/ecto-analytical-coverage.md docs/public-api-audit.md docs/protocol guides lib mix.exs),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/elixir-vibe/quackdb",
        "DuckDB" => "https://duckdb.org/"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CONTRIBUTING.md",
        "guides/getting-started.md",
        "guides/type-support.md",
        "guides/examples.md",
        "guides/managed-duckdb.md",
        "guides/explorer.md",
        "guides/sources.md",
        "guides/spatial.md",
        "guides/full-text-search.md",
        "guides/telemetry.md",
        "docs/protocol/coverage.md",
        "docs/protocol/fixtures.md",
        "docs/ecto-analytical-coverage.md",
        "docs/public-api-audit.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\//,
        Examples: ~r/examples\//,
        Reference: ~r/docs\//
      ],
      filter_modules: &public_doc_module?/2
    ]
  end

  defp public_doc_module?(module, _metadata) do
    name = Atom.to_string(module)

    not (name in internal_doc_modules() or String.starts_with?(name, "Elixir.QuackDB.Protocol.") or
           String.starts_with?(name, "Elixir.Mix.Tasks."))
  end

  defp internal_doc_modules do
    Enum.map(
      [
        QuackDB.Application,
        QuackDB.DBConnection,
        QuackDB.Inspect,
        QuackDB.Protocol,
        QuackDB.Transport,
        QuackDB.Transport.Mint,
        QuackDB.URI
      ],
      &Atom.to_string/1
    )
  end
end

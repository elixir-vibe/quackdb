defmodule QuackDB.MixProject do
  use Mix.Project

  def project do
    [
      app: :quackdb,
      version: "0.1.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
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

  defp deps do
    [
      {:db_connection, "~> 2.7"},
      {:req, "~> 0.5"},
      {:decimal, "~> 2.0"},
      {:ecto_sql, "~> 3.13", optional: true},
      {:explorer, "~> 0.11", optional: true},
      {:stream_data, "~> 1.2", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]
    ]
  end

  defp package do
    [
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
        "guides/getting-started.md",
        "guides/type-support.md",
        "docs/research.md",
        "docs/postgrex-comparison.md",
        "docs/duckdb-capabilities.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\//,
        Research: ~r/docs\//
      ]
    ]
  end
end

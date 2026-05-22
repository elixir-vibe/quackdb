defmodule QuackDB.MixProject do
  use Mix.Project

  def project do
    [
      app: :quackdb_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: "Remote DuckDB Quack protocol client for Elixir"
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
      links: %{}
    ]
  end
end

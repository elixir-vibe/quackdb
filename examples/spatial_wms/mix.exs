defmodule SpatialWms.MixProject do
  use Mix.Project

  def project do
    [
      app: :spatial_wms,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SpatialWms.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:quackdb, path: "../.."},
      {:ecto_sql, "~> 3.13"},
      {:ash, "~> 3.0"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"}
    ]
  end
end

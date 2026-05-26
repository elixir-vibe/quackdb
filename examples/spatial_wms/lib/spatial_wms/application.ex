defmodule SpatialWMS.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {server_children, repo_config} = quackdb_config()

    Application.put_env(:spatial_wms, SpatialWMS.Repo, repo_config)

    port = System.get_env("PORT", "4040") |> String.to_integer()

    children =
      server_children ++
        [
          SpatialWMS.Repo,
          {Bandit, plug: SpatialWMS.Web.Router, port: port}
        ]

    with {:ok, supervisor} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: SpatialWMS.Supervisor) do
      SpatialWMS.Places.init!()
      print_routes(port)
      {:ok, supervisor}
    end
  end

  defp quackdb_config do
    case System.get_env("QUACKDB_URI") do
      nil ->
        token = "super_secret"

        {
          [{QuackDB.Server, name: SpatialWMS.DuckDB, token: token}],
          [uri: "http://[::1]:9494", token: token, pool_size: 1, log: false]
        }

      uri ->
        {[], [uri: uri, token: System.get_env("QUACKDB_TOKEN", ""), pool_size: 1, log: false]}
    end
  end

  defp print_routes(port) do
    IO.puts("Spatial WMS example running on http://localhost:#{port}")
    IO.puts("Capabilities:")
    IO.puts("  #{url(port, service: "WMS", request: "GetCapabilities")}")
    IO.puts("GeoJSON GetMap:")

    IO.puts(
      "  #{url(port, service: "WMS", request: "GetMap", layers: "places", crs: "EPSG:4326", bbox: "-180,-90,180,90", width: 800, height: 400, format: "application/geo+json")}"
    )
  end

  defp url(port, params) do
    URI.to_string(%URI{
      scheme: "http",
      host: "localhost",
      port: port,
      path: "/",
      query: URI.encode_query(params)
    })
  end
end

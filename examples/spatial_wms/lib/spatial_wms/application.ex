defmodule SpatialWms.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:spatial_wms, SpatialWms.Repo,
      uri: System.get_env("QUACKDB_TEST_URI", "http://localhost:9494"),
      token: System.get_env("QUACKDB_TEST_TOKEN", "super_secret"),
      pool_size: 1,
      log: false
    )

    port = System.get_env("PORT", "4040") |> String.to_integer()

    children = [
      SpatialWms.Repo,
      {Bandit, plug: SpatialWmsWeb.Router, port: port}
    ]

    with {:ok, supervisor} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: SpatialWms.Supervisor) do
      SpatialWms.Places.init!()
      print_routes(port)
      {:ok, supervisor}
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

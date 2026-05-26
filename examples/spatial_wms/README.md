# Spatial WMS example

A minimal QuackDB application that serves DuckDB Spatial data through a WMS-like GeoJSON endpoint.

It intentionally combines:

- **QuackDB** for remote DuckDB over Quack
- **Ecto** via `SpatialWMS.Repo`
- **QuackDB.Ecto.Spatial** for spatial query expressions
- **Ash** for the `Place` resource and code interface at the boundary
- **Geo** for WKB → GeoJSON conversion
- **Plug/Bandit** for HTTP

This is a small GeoJSON profile of WMS rather than a complete OGC implementation. It supports:

- `SERVICE=WMS&REQUEST=GetCapabilities`
- `SERVICE=WMS&REQUEST=GetMap&LAYERS=places&CRS=EPSG:4326&BBOX=minx,miny,maxx,maxy&FORMAT=application/geo+json`

## Run

Run the app:

```sh
cd examples/spatial_wms
mix run --no-halt
```

By default it starts a local DuckDB Quack server with `QuackDB.Server`. To use an existing server, pass `QUACKDB_URI` and optional `QUACKDB_TOKEN`:

```sh
QUACKDB_URI='http://[::1]:9494' QUACKDB_TOKEN=super_secret mix run --no-halt
```

Try capabilities:

```sh
curl 'http://localhost:4040/?SERVICE=WMS&REQUEST=GetCapabilities'
```

Try GeoJSON GetMap. `FORMAT` contains reserved URL characters, so build the query string with `URI.encode_query/1` instead of hand-encoding it:

```sh
elixir -e 'IO.puts("http://localhost:4040/?" <> URI.encode_query(service: "WMS", request: "GetMap", layers: "places", crs: "EPSG:4326", bbox: "-180,-90,180,90", width: 800, height: 400, format: "application/geo+json"))' \
  | xargs curl
```

Example response:

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": 2,
      "properties": {"name": "London"},
      "geometry": {"type": "Point", "coordinates": [-0.1276, 51.5072]}
    }
  ]
}
```

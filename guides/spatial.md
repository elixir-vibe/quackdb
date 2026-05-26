# Spatial

QuackDB includes helpers for DuckDB's spatial extension and optional conversion between DuckDB `GEOMETRY` values and Elixir `Geo` structs.

## Load DuckDB spatial

```elixir
alias QuackDB.Spatial

QuackDB.query!(conn, Spatial.load())
```

For a supervised local demo server, use `QuackDB.Server` and then load the extension on the client connection.

## Ecto spatial helpers

`QuackDB.Ecto.Spatial` wraps DuckDB spatial functions in Ecto fragments so spatial expressions can stay in normal Ecto queries:

```elixir
use QuackDB.Ecto

query =
  from place in "places",
    where: intersects(place.geom, envelope(^min_x, ^min_y, ^max_x, ^max_y)),
    order_by: place.id,
    select: %{
      id: place.id,
      name: place.name,
      wkt: as_text(place.geom),
      geojson: as_geojson(place.geom)
    }

MyApp.AnalyticsRepo.all(query)
```

For creating geometry expressions in Ecto queries:

```elixir
from place in "places",
  where: distance(place.geom, point(^lon, ^lat)) < ^meters,
  select: %{id: place.id, geometry: as_wkb(place.geom)}
```

Available helpers include `point/2`, `as_wkb/1`, `as_hex_wkb/1`, `as_text/1`, `as_geojson/1`, `geom_from_wkb/1`, `geom_from_text/1`, `envelope/4`, `intersects/2`, `contains/2`, and `distance/2`.

DuckDB `GEOMETRY` values decode as WKB-compatible binaries.

## Optional Geo conversion

Add the optional `:geo` package when you want Elixir geometry structs:

```elixir
{:geo, "~> 4.1"}
```

Then convert decoded WKB bytes:

```elixir
alias QuackDB.Geometry

geo = Geometry.to_geo!(wkb)
wkb = Geometry.from_geo!(geo)
```

`%Geo.*{}` structs can also be passed as SQL/Ecto parameters when `:geo` is available.

## WMS-style example

[`examples/spatial_wms/`](https://github.com/elixir-vibe/quackdb/tree/master/examples/spatial_wms) is a minimal Ash + Ecto + Plug/Bandit app that serves DuckDB Spatial rows through a WMS-like GeoJSON endpoint.

It demonstrates:

- `QuackDB.Server` for local DuckDB Quack supervision
- Ecto queries with `QuackDB.Ecto.Spatial`
- Ash resource structs at the HTTP boundary
- WMS-style `GetCapabilities` and `GetMap` requests

It is a small GeoJSON profile of WMS, not a complete OGC WMS implementation.

# Spatial

QuackDB includes helpers for DuckDB's spatial extension and optional conversion between DuckDB `GEOMETRY` values and Elixir `Geo` structs.

## Load DuckDB spatial

```elixir
QuackDB.query!(conn, QuackDB.Spatial.load())
```

For a supervised local demo server, use `QuackDB.Server` and then load the extension on the client connection.

## Raw SQL helpers

`QuackDB.Spatial` builds SQL fragments for DuckDB `ST_*` functions:

```elixir
alias QuackDB.Spatial

point = Spatial.point(1, 2)

QuackDB.query!(conn, [
  "SELECT ",
  point,
  " AS geom, ",
  Spatial.as_text(point),
  " AS wkt, ",
  Spatial.as_geojson(point),
  " AS geojson"
])
```

DuckDB `GEOMETRY` values decode as WKB-compatible binaries.

## Optional Geo conversion

Add the optional `:geo` package when you want Elixir geometry structs:

```elixir
{:geo, "~> 4.1"}
```

Then convert decoded WKB bytes:

```elixir
geo = QuackDB.Geometry.to_geo!(wkb)
wkb = QuackDB.Geometry.from_geo!(geo)
```

`%Geo.*{}` structs can also be passed as SQL/Ecto parameters when `:geo` is available.

## Ecto spatial helpers

`QuackDB.Ecto.Spatial` wraps spatial functions in Ecto fragments:

```elixir
import Ecto.Query
import QuackDB.Ecto.Spatial

bbox = envelope(^min_x, ^min_y, ^max_x, ^max_y)

from place in "places",
  where: intersects(place.geom, bbox),
  select: %{id: place.id, geometry: as_geojson(place.geom)}
```

Available helpers include `point/2`, `as_wkb/1`, `as_hex_wkb/1`, `as_text/1`, `as_geojson/1`, `geom_from_wkb/1`, `geom_from_text/1`, `envelope/4`, `intersects/2`, `contains/2`, and `distance/2`.

## WMS-style example

[`examples/spatial_wms/`](examples/spatial_wms/README.md) is a minimal Ash + Ecto + Plug/Bandit app that serves DuckDB Spatial rows through a WMS-like GeoJSON endpoint.

It demonstrates:

- `QuackDB.Server` for local DuckDB Quack supervision
- Ecto queries with `QuackDB.Ecto.Spatial`
- Ash resource structs at the HTTP boundary
- WMS-style `GetCapabilities` and `GetMap` requests

It is a small GeoJSON profile of WMS, not a complete OGC WMS implementation.

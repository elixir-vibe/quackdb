# QuackDB Examples

These examples show QuackDB as an Elixir-native analytics bridge: DuckDB over Quack, DBConnection, Ecto, Explorer, Table.Reader, telemetry, and spatial workflows.

Examples start a local DuckDB Quack server with `QuackDB.Server` unless `QUACKDB_URI` is set. Use `QUACKDB_TOKEN` when your existing server requires a token.

## Query observability

[`query_observability.exs`](query_observability.exs) attaches telemetry handlers and prints query, append, and fetch timings while inserting and reading a small table.

Run from outside the Mix project:

```sh
cd /tmp
elixir /path/to/quackdb/examples/query_observability.exs
```

## Dataframe analytics

[`dataframe_analytics.exs`](dataframe_analytics.exs) shows an Ecto schema-driven setup flow:

1. derive DuckDB DDL from an Ecto schema with `QuackDB.DDL.create_table/2`
2. append an `Explorer.DataFrame` with native column append
3. query with Ecto DSL
4. return an Explorer dataframe

```sh
cd /tmp
elixir /path/to/quackdb/examples/dataframe_analytics.exs
```

## Append benchmark

[`append_benchmark.exs`](append_benchmark.exs) compares SQL inserts, native row append, native column append, Explorer dataframe append, Ecto SQL `insert_all`, and Ecto native append. Tiny row counts mostly measure round-trip overhead; use larger `ROWS` values for meaningful append comparisons.

```sh
cd /tmp
ROWS=1000 BATCH_SIZE=1000 elixir /path/to/quackdb/examples/append_benchmark.exs
```

## Livebook analytics

[`livebook_analytics.livemd`](livebook_analytics.livemd) is an interactive notebook using Explorer, Table.Reader, VegaLite, telemetry, and a local `QuackDB.Server`.

## Spatial WMS

[`spatial_wms/`](spatial_wms/README.md) is a minimal Ash + Ecto + Plug/Bandit app serving DuckDB Spatial rows through a WMS-like GeoJSON endpoint.

It supports:

- `SERVICE=WMS&REQUEST=GetCapabilities`
- `SERVICE=WMS&REQUEST=GetMap&LAYERS=places&CRS=EPSG:4326&BBOX=minx,miny,maxx,maxy&FORMAT=application/geo+json`

This is a small GeoJSON profile of WMS, not a complete OGC WMS implementation.

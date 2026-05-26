# QuackDB Examples

These examples show QuackDB as an Elixir-native analytics bridge: DuckDB over Quack, DBConnection, Ecto, Explorer, Table.Reader, telemetry, and spatial workflows.

Examples start a local DuckDB Quack server with `QuackDB.Server` and `duckdb: :managed` unless `QUACKDB_URI` is set. Use `QUACKDB_TOKEN` when your existing server requires a token.

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

## Stream append

[`stream_append.exs`](stream_append.exs) parses newline-delimited JSON as an Elixir stream and appends it with `QuackDB.insert_stream!/4` in small native append batches.

```sh
cd /tmp
elixir /path/to/quackdb/examples/stream_append.exs
```

## Append benchmark

[`append_benchmark.exs`](append_benchmark.exs) compares SQL inserts, native row append, native column append, Explorer dataframe append, Ecto SQL `insert_all`, and Ecto native append. Tiny row counts mostly measure round-trip overhead; use larger `ROWS` values for meaningful append comparisons.

```sh
cd /tmp
ROWS=1000 BATCH_SIZE=1000 elixir /path/to/quackdb/examples/append_benchmark.exs
```

Use smoke mode when you only want to verify each path once:

```sh
cd /tmp
SMOKE=1 ROWS=10 BATCH_SIZE=5 elixir /path/to/quackdb/examples/append_benchmark.exs
```

## Full-text search

[`full_text_search.exs`](full_text_search.exs) creates a DuckDB FTS index, runs direct SQL BM25 search, and runs the same search through Ecto fragments.

```sh
cd /tmp
elixir /path/to/quackdb/examples/full_text_search.exs
```

## Livebook analytics

[`livebook_analytics.livemd`](livebook_analytics.livemd) is an interactive notebook using Explorer, Table.Reader, VegaLite, telemetry, and a local `QuackDB.Server`.

## Spatial WMS

[`spatial_wms/`](spatial_wms/README.md) is a minimal Ash + Ecto + Plug/Bandit app serving DuckDB Spatial rows through a WMS-like GeoJSON endpoint.

It supports:

- `SERVICE=WMS&REQUEST=GetCapabilities`
- `SERVICE=WMS&REQUEST=GetMap&LAYERS=places&CRS=EPSG:4326&BBOX=minx,miny,maxx,maxy&FORMAT=application/geo+json`

This is a small GeoJSON profile of WMS, not a complete OGC WMS implementation.

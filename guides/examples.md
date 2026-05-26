# Examples

The examples directory shows QuackDB as an Elixir-native bridge to DuckDB analytics.

Examples start a local DuckDB Quack server with `QuackDB.Server` unless `QUACKDB_URI` is set. This keeps the examples runnable without asking you to manually start DuckDB.

## Query observability

[`examples/query_observability.exs`](examples/query_observability.exs) attaches telemetry handlers and prints query, append, and fetch timings.

```sh
cd /tmp
elixir /path/to/quackdb/examples/query_observability.exs
```

## Dataframe analytics

[`examples/dataframe_analytics.exs`](examples/dataframe_analytics.exs) demonstrates:

1. deriving DuckDB DDL from an Ecto schema
2. appending an `Explorer.DataFrame` through native column append
3. querying with Ecto DSL
4. returning an Explorer dataframe

```sh
cd /tmp
elixir /path/to/quackdb/examples/dataframe_analytics.exs
```

## Livebook analytics

[`examples/livebook_analytics.livemd`](examples/livebook_analytics.livemd) is an interactive notebook using Explorer, Table.Reader, VegaLite, telemetry, and a local `QuackDB.Server`.

## Spatial WMS

[`examples/spatial_wms/`](examples/spatial_wms/README.md) is a minimal Ash + Ecto + Plug/Bandit application serving DuckDB Spatial rows through a WMS-like GeoJSON endpoint.

```sh
cd examples/spatial_wms
mix run --no-halt
```

## Existing servers

To use an existing DuckDB Quack server instead of `QuackDB.Server`, set:

```sh
QUACKDB_URI='http://[::1]:9494'
QUACKDB_TOKEN=super_secret
```

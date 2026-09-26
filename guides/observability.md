# Observability

Results are `Table.Reader` tables, every operation emits telemetry, and DuckDB's own profiling, storage, and catalog metadata are reachable as structs.

## Results and Livebook

`QuackDB.Result` and `QuackDB.Columns` implement `Table.Reader`, so they can be consumed by Livebook and other Table-aware tooling. When Explorer is installed, query results can be turned into dataframes:

```elixir
result = QuackDB.query!(conn, "SELECT * FROM events")
Explorer.DataFrame.new(result)
```

## Telemetry

QuackDB emits telemetry spans for query, append, and fetch operations:

- `[:quackdb, :query, :start | :stop]`
- `[:quackdb, :append, :start | :stop]`
- `[:quackdb, :fetch, :start | :stop]`

Metadata includes connection/session information, command details, append batch counts, and client query IDs. Params are not included unless you opt in with `telemetry_params: true`. See the [telemetry guide](telemetry.md).

## Profiling

Use `QuackDB.Profile` when you need DuckDB engine/operator timings rather than client-side telemetry:

```elixir
profile =
  QuackDB.Profile.analyze!(conn,
    "SELECT i, i % 10 AS bucket FROM range(1000) t(i) ORDER BY bucket LIMIT 5"
  )

QuackDB.Profile.slowest(profile, 5)
IO.puts(QuackDB.Profile.report(profile))
```

`QuackDB.Profile` runs DuckDB `EXPLAIN (ANALYZE, FORMAT json)` and returns structs for query/root metrics and operator nodes. `QuackDB.SQL.explain/2` also supports `format: :json`, `:html`, `:graphviz`, `:mermaid`, and `:text`.

## Storage

Use `QuackDB.Storage` to inspect how DuckDB stores and compresses tables:

```elixir
QuackDB.Storage.info!(MyApp.AnalyticsRepo, MyApp.Fragment)
QuackDB.Storage.compression!(MyApp.AnalyticsRepo, MyApp.Fragment)
QuackDB.Storage.database_size!(MyApp.AnalyticsRepo)
QuackDB.Storage.checkpoint!(MyApp.AnalyticsRepo)
```

`info!/2` wraps DuckDB's `pragma_storage_info` output as segment structs. `compression!/2` groups segment compression by table column, accepting schema modules, atoms, strings, and `{prefix, source}` tuples.

## Catalog metadata

Use `QuackDB.Meta` for logical catalog metadata:

```elixir
QuackDB.Meta.tables!(MyApp.AnalyticsRepo)
QuackDB.Meta.tables!(MyApp.AnalyticsRepo, expanded: true)
QuackDB.Meta.table_info!(MyApp.AnalyticsRepo, MyApp.Fragment)
QuackDB.Meta.databases!(MyApp.AnalyticsRepo)
```

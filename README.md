# QuackDB

[![Hex.pm](https://img.shields.io/hexpm/v/quackdb.svg)](https://hex.pm/packages/quackdb)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/quackdb)

Remote DuckDB analytics from Elixir, backed by DuckDB's experimental Quack protocol.

`quackdb` lets Elixir applications query and append to a remote DuckDB process without embedding DuckDB in the BEAM. It provides a `DBConnection`-first client, direct Quack protocol decoding, streaming result fetches, native append writes, source helpers for analytical files and lakehouse tables, and optional Ecto/Explorer integrations.

> [!WARNING]
> QuackDB itself is experimental and not production-ready. The package API, result shapes, Ecto adapter behavior, and supported type coverage may change as the project evolves. It also targets DuckDB's experimental Quack protocol, which may change across DuckDB releases. Use it at your own risk, validate behavior against your DuckDB version, and avoid relying on it for critical production workloads yet.

## Status

QuackDB currently focuses on the remote protocol and `DBConnection` client core. It supports:

- `DBConnection`-backed remote DuckDB queries over Quack HTTP endpoints
- streaming and fetch continuation for large analytical result sets
- native append writes through DuckDB `DataChunk`s via `QuackDB.insert_rows/4`
- rich DuckDB scalar fidelity including decimals, UUIDs, enums, `BIGNUM`, nanosecond temporal values, intervals, and `TIME WITH TIME ZONE`
- nested DuckDB values such as `LIST`, `STRUCT`, `ARRAY`, and `MAP`
- source helpers for Parquet, CSV, JSON, XLSX, Delta, and Iceberg table functions
- column-oriented result helpers for analytical/vector-style workflows
- optional Ecto SQL adapter support for raw SQL, analytical reads, `insert/2`, and `insert_all/3`
- optional Explorer dataframe handoff helpers and `Table.Reader` support for Livebook-friendly tabular data
- supervised local DuckDB Quack server processes for development
- `:telemetry` events for query, append, and fetch operations

Raw SQL can use the full DuckDB surface. Ecto query generation is growing toward analytical DuckDB usage while keeping unsupported features explicit.

## Why QuackDB?

Use QuackDB when you want DuckDB's analytical SQL from Elixir while keeping DuckDB in a separate process.

That gives you:

- a normal OTP/`DBConnection` client surface
- remote DuckDB execution instead of embedding native database state in your BEAM
- efficient protocol-level result decoding
- explicit unsupported-feature errors instead of silent lossy behavior
- optional Ecto and Explorer layers without making them required

## Examples

The `examples/` directory includes runnable scripts and a Livebook notebook:

- `examples/query_observability.exs` — attach telemetry handlers and print query, append, and fetch timings.
- `examples/dataframe_analytics.exs` — derive DDL from an Ecto schema, append an `Explorer.DataFrame`, query with Ecto DSL, and return a dataframe.
- `examples/livebook_analytics.livemd` — an interactive analytics notebook with DuckDB SQL, Explorer, Table.Reader, VegaLite, and telemetry.
- `examples/spatial_wms/` — a minimal Ash + Ecto + Plug/Bandit app serving DuckDB Spatial rows through a WMS-like GeoJSON endpoint.
- `examples/append_benchmark.exs` — compares SQL inserts, native row/column append, Explorer append, and Ecto insert paths.
- `examples/support/quackdb_demo.exs` — shared demo boot helper that starts `QuackDB.Server` unless `QUACKDB_URI` is set.

Run scripts from outside the Mix project so `Mix.install/2` can load the local package. Examples start a local DuckDB Quack server with `QuackDB.Server` unless `QUACKDB_URI` is set:

```sh
cd /tmp
elixir /path/to/quackdb/examples/dataframe_analytics.exs
```

## Installation

Add `:quackdb` to your dependencies:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"}
  ]
end
```

DuckDB's Quack protocol is currently experimental. For local testing, use DuckDB 1.5.3 or newer with the `quack` extension.

Optional integrations are compiled only when their packages are available. Add Explorer when you want dataframe handoff helpers:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"},
    {:explorer, "~> 0.11"}
  ]
end
```

## Start a DuckDB Quack server

For local development, QuackDB can supervise DuckDB's external CLI process for you:

```elixir
children = [
  {QuackDB.Server,
   name: MyApp.DuckDB,
   endpoint: "quack:localhost:9494",
   uri: "http://[::1]:9494",
   token: "super_secret"},

  {QuackDB,
   name: MyApp.QuackDB,
   uri: "http://[::1]:9494",
   token: "super_secret"}
]
```

Or start DuckDB manually:

```sh
duckdb -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

`quack:localhost` may bind on IPv6 localhost, so the examples use `http://[::1]:9494`.

## Usage

### Connect

```elixir
{:ok, conn} =
  QuackDB.start_link(
    uri: "http://[::1]:9494",
    token: "super_secret"
  )
```

### Query

```elixir
:ok = QuackDB.ping(conn)

{:ok, result} = QuackDB.query(conn, "SELECT 1 AS n")

result.columns
#=> ["n"]

result.rows
#=> [[1]]
```

QuackDB formats positional parameters as DuckDB SQL literals client-side because the current Quack request path does not expose server-side bind parameters:

```elixir
{:ok, result} = QuackDB.query(conn, "SELECT ? AS name, ? AS n", ["duck", 42])

result.rows
#=> [["duck", 42]]
```

Placeholders inside strings and comments are ignored while formatting, and unsupported parameter values raise explicit errors.

Results use compact IEx-friendly inspection so large result sets do not flood the console:

```elixir
#QuackDB.Result<command: :select, columns: ["n"], rows: 1, preview: [[1]], connection_id: "...", needs_more_fetch?: false>
```

### Nested DuckDB values

DuckDB nested types decode to ordinary Elixir terms:

```elixir
{:ok, result} =
  QuackDB.query(conn, """
  SELECT
    [1, 2, 3] AS xs,
    {'name': 'duck', 'count': 2} AS obj,
    array_value(1, 2, 3) AS arr,
    map(['a', 'b'], [1, 2]) AS m
  """)

result.rows
#=> [[[1, 2, 3], %{"name" => "duck", "count" => 2}, [1, 2, 3], %{"a" => 1, "b" => 2}]]
```

### Source helpers

DuckDB can scan files, object stores, and lakehouse table formats directly. `QuackDB.Source` builds safe table-function fragments for raw SQL:

```elixir
source =
  QuackDB.Source.parquet("s3://bucket/events/*.parquet",
    hive_partitioning: true,
    union_by_name: true
  )

QuackDB.query!(conn, ["SELECT category, count(*) FROM ", source, " GROUP BY category"])
```

Available helpers include `parquet/2`, `csv/2`, `json/2`, `xlsx/2`, `delta/2`, and `iceberg/2`. Options are emitted as DuckDB named parameters, and paths/options are formatted as SQL literals instead of interpolated directly.

The same fragments can be used as Ecto sources for read-oriented analytical queries:

```elixir
source = QuackDB.Source.csv("events.csv", header: true)

MyApp.AnalyticsRepo.all(
  from event in source,
    where: event.id > 1,
    select: %{id: event.id, name: event.name}
)
```

### Streaming

`QuackDB.query/4` materializes the full result. Use streaming helpers for large analytical result sets.

`QuackDB.stream/4` yields `%QuackDB.Result{}` batches:

```elixir
row_count =
  conn
  |> QuackDB.stream("SELECT i FROM range(0, 50_000) t(i)")
  |> Enum.reduce(0, fn result, count -> count + result.num_rows end)

row_count
#=> 50_000
```

`QuackDB.rows/4` yields row lists:

```elixir
conn
|> QuackDB.rows("SELECT i FROM range(0, ?) t(i)", [50_000])
|> Enum.take(3)
#=> [[0], [1], [2]]
```

`QuackDB.maps/4` yields maps keyed by column names. Duplicate column names are disambiguated with suffixes such as `_2` and `_3`:

```elixir
conn
|> QuackDB.maps("SELECT i AS n FROM range(0, ?) t(i)", [50_000])
|> Enum.take(2)
#=> [%{"n" => 0}, %{"n" => 1}]
```

Use `QuackDB.columnar/4` when an analytical workflow wants vectors plus column order and metadata:

```elixir
{:ok, columns} = QuackDB.columnar(conn, "SELECT id, name FROM events ORDER BY id")

columns.names
#=> ["id", "name"]

columns["id"]
#=> [1, 2]
```

`QuackDB.columns/4` returns just the column map:

```elixir
{:ok, columns} = QuackDB.columns(conn, "SELECT id, name FROM events ORDER BY id")

columns
#=> %{"id" => [1, 2], "name" => ["duck", "goose"]}
```

For large results, `QuackDB.columnar_batches/4` streams `QuackDB.Columns` fetch batches without materializing the whole result set. `QuackDB.column_batches/4` returns just the map from each batch:

```elixir
conn
|> QuackDB.column_batches("SELECT i AS n FROM range(0, 50_000) t(i)", [], max_rows: 1_000)
|> Enum.take(1)
#=> [%{"n" => [0, 1, 2, ...]}]
```

This is not Arrow IPC yet, but it exposes a column-oriented shape that can back future Arrow integration without changing the query API.

### Explorer DataFrames

When `:explorer` is available, QuackDB exposes optional helpers for building `Explorer.DataFrame` values from query results:

```elixir
{:ok, df} =
  QuackDB.Explorer.dataframe(conn, "SELECT id, name FROM events ORDER BY id")
```

You can also pass Ecto queries directly, including source helpers:

```elixir
source = QuackDB.Source.csv("events.csv", header: true)

query =
  from event in source,
    where: event.id > ^1,
    select: %{id: event.id, name: event.name}

{:ok, df} = QuackDB.Explorer.dataframe(conn, query)
```

The Explorer integration materializes query results in Elixir before constructing a dataframe. It is useful for interactive analysis and downstream Explorer pipelines, but it is not a zero-copy Arrow IPC path yet.

Explorer dataframes can also be appended through Quack's native column-oriented append path:

```elixir
QuackDB.Explorer.insert_dataframe!(conn, "events_copy", df, batch_size: 10_000)
```

You can also convert existing results:

```elixir
{:ok, result} = QuackDB.query(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackDB.Explorer.from_result(result)

{:ok, columns} = QuackDB.columnar(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackDB.Explorer.from_columns(columns)
```

When the optional `:table` package is available, `QuackDB.Result` and `QuackDB.Columns` implement `Table.Reader`, so Livebook and Table-aware libraries can consume query results directly.

### Telemetry

QuackDB emits `:telemetry` spans for direct query, append, and fetch operations:

```elixir
[:quackdb, :query, :start]
[:quackdb, :query, :stop]
[:quackdb, :append, :start]
[:quackdb, :append, :stop]
[:quackdb, :fetch, :start]
[:quackdb, :fetch, :stop]
```

Use `:telemetry_prefix` on the connection to customize event names:

```elixir
{QuackDB, uri: "http://localhost:9494", telemetry_prefix: [:my_app, :quackdb]}
```

Then query events are emitted as `[:my_app, :quackdb, :query, :stop]`. Per-operation `:telemetry_options` are copied into metadata, and params are included only when `telemetry_params: true` is passed:

```elixir
QuackDB.query!(conn, "SELECT ?", [1],
  telemetry_options: [request_id: "req-1"],
  telemetry_params: true
)
```

Append metadata includes the target table, row count, batch count, and batch size.

### Command results

DuckDB returns affected-row counts through a `Count` column. QuackDB normalizes those into `num_rows` for command results:

```elixir
{:ok, _} = QuackDB.query(conn, "CREATE TEMP TABLE events(id INTEGER)")
{:ok, result} = QuackDB.query(conn, "INSERT INTO events VALUES (1), (2)")

result.command
#=> :insert

result.num_rows
#=> 2

result.rows
#=> nil
```

The original DuckDB shape is preserved in metadata for debugging:

```elixir
result.metadata[:duckdb_columns]
#=> ["Count"]

result.metadata[:duckdb_rows]
#=> [[2]]
```

### Append rows

`QuackDB.insert_rows/4` uses Quack's append protocol to send a DuckDB `DataChunk` directly to a table:

```elixir
QuackDB.query!(conn, "CREATE TEMP TABLE events(id INTEGER, name VARCHAR, active BOOLEAN)")

{:ok, result} =
  QuackDB.insert_rows(conn, "events", [
    [id: 1, name: "duck", active: true],
    [id: 2, name: "goose", active: false]
  ])

result.command
#=> :insert

result.num_rows
#=> 2
```

Keyword rows preserve append order and allow QuackDB to infer the column list from the first row. Map rows are also accepted, but pass `:columns` for stable append order and types. Explicit columns are still required for empty batches or all-null columns. Use `batch_size: n` to split large inputs across multiple append requests while returning the total inserted row count.

For large in-memory batches that are already column-shaped, use `QuackDB.insert_columns/4` to avoid building row maps or keyword rows:

```elixir
QuackDB.insert_columns(conn, "events",
  id: [1, 2],
  name: ["duck", "goose"],
  active: [true, false]
)
```

Native append columns can be declared with scalar `QuackDB.Type` specs and nested specs such as `{:list, :varchar}`, `{:struct, [source: :varchar, count: :integer]}`, `{:array, :integer, 3}`, and `{:map, :varchar, :varchar}`. Temporal append values are normalized through Elixir's Calendar-aware `Date`, `Time`, `NaiveDateTime`, and `DateTime` conversion APIs before encoding.

### Spatial helpers

DuckDB's spatial extension can be loaded with SQL helpers:

```elixir
QuackDB.query!(conn, QuackDB.Spatial.load())
```

Prefer Ecto spatial helpers for application queries:

```elixir
import Ecto.Query
import QuackDB.Ecto.Spatial

point = %Geo.Point{coordinates: {1.0, 2.0}, srid: nil}

from(place in "places",
  where: intersects(place.geom, ^point),
  select: %{id: place.id, wkt: as_text(place.geom), geojson: as_geojson(place.geom)}
)
```

DuckDB `GEOMETRY` values decode as WKB-compatible bytes. Add optional `{:geo, "~> 4.1"}` when you want to convert those bytes to `Geo` structs with `QuackDB.Geometry.decode_wkb!/1`, or pass `%Geo.*{}` structs as SQL/Ecto parameters.

### Prepare and execute

```elixir
{:ok, query, result} = QuackDB.prepare_execute(conn, "SELECT 1 AS n")

query.columns
#=> ["n"]

result.rows
#=> [[1]]
```

### Ecto raw SQL

QuackDB includes an initial Ecto SQL adapter for raw SQL queries. If your app does not already depend on Ecto SQL, add it alongside QuackDB:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"},
    {:ecto_sql, "~> 3.13"}
  ]
end
```

Then define a repo:

```elixir
defmodule MyApp.AnalyticsRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

Configure the repo with the same connection options used by `QuackDB.start_link/1`:

```elixir
config :my_app, MyApp.AnalyticsRepo,
  uri: "http://[::1]:9494",
  token: "super_secret"
```

Then use `Repo.query/3`:

```elixir
{:ok, result} = MyApp.AnalyticsRepo.query("SELECT 1 AS n")

result.rows
#=> [[1]]
```

Raw SQL and generated DDL also work inside Ecto transactions:

```elixir
{:ok, :committed} =
  MyApp.AnalyticsRepo.transaction(fn ->
    MyApp.AnalyticsRepo.query!(
      QuackDB.DDL.create_table("events", [id: :integer], temporary: true)
    )

    MyApp.AnalyticsRepo.query!("INSERT INTO events VALUES (1), (2)")
    :committed
  end)
```

Use `Repo.rollback/1` to abort transaction work:

```elixir
{:error, :rolled_back} =
  MyApp.AnalyticsRepo.transaction(fn ->
    MyApp.AnalyticsRepo.query!("INSERT INTO events VALUES (3)")
    MyApp.AnalyticsRepo.rollback(:rolled_back)
  end)
```

Read-only Ecto queries against table names are also supported, including CTEs, window functions, joins, grouping, having, distinct, aggregate `FILTER`, arithmetic expressions, `in/2`, predicates, ordering, limits, aggregates, fragments, and DuckDB analytical helpers:

```elixir
import Ecto.Query
import QuackDB.Ecto.Analytics

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: event.id > ^min_id and like(event.name, "d%"),
    group_by: event.category,
    select: %{
      category: event.category,
      median_score: median(event.score),
      p95_score: quantile_cont(event.score, 0.95),
      scores: duckdb_list(event.score)
    }
)
```

Ecto `insert/2` and `insert_all/3` are supported for straightforward row inserts. DuckDB `RETURNING` works through the SQL insert path:

```elixir
MyApp.AnalyticsRepo.insert!(%Event{id: 1, name: "duck"})

MyApp.AnalyticsRepo.insert_all(
  "events",
  [[id: 2, name: "goose"]],
  returning: [:id]
)
```

Use `insert_method: :append` to opt into Quack's native append protocol for plain `insert_all` workloads. This fast path does not support query inserts, `:returning`, placeholders, or upserts.

```elixir
MyApp.AnalyticsRepo.insert_all(
  "events",
  [[id: 1, name: "duck"], [id: 2, name: "goose"]],
  insert_method: :append,
  chunk_every: 10_000
)
```

For temporary analytical setup, `QuackDB.DDL.create_table/3` builds quoted DuckDB `CREATE TABLE` statements. It can also derive columns from an Ecto schema:

```elixir
defmodule Event do
  use Ecto.Schema

  @primary_key false
  schema "events" do
    field :id, :integer
    field :category, :string
    field :score, :float
  end
end

MyApp.AnalyticsRepo.query!(QuackDB.DDL.create_table(Event, temporary: true))
```

For expression-heavy inserts in setup code, `QuackDB.DML.insert_into/2` keeps identifiers and literals quoted while allowing explicit SQL expressions:

```elixir
MyApp.AnalyticsRepo.query!(
  QuackDB.DML.insert_into("places",
    id: 1,
    name: "London",
    geom: {:expr, QuackDB.Spatial.point(-0.1276, 51.5072)}
  )
)
```

Ecto support is analytical rather than CRUD-shaped, but still early. Migrations, set combinations, locks, updates, deletes, and upserts raise explicit unsupported-feature errors for now.

## Current limitations

- Bind parameters are not exposed through this Quack client path yet.
- Native appends support row batches but not Arrow IPC or automatic local-file/data staging yet.
- Ecto support is limited to raw SQL, read-only analytical table queries, and straightforward `insert_all/3` row inserts.
- The low-level protocol is experimental and tracks DuckDB's Quack extension behavior.

## Supervision and connection options

Use QuackDB under your application supervisor when you want a long-lived connection pool:

```elixir
children = [
  {QuackDB,
   uri: "http://[::1]:9494",
   token: "super_secret",
   name: MyApp.QuackDB,
   pool_size: 5}
]
```

The client accepts QuackDB options such as `:uri`, `:token`, and `:transport`, plus DBConnection pool options such as `:name`, `:pool_size`, `:queue_target`, `:queue_interval`, and `:timeout` on individual calls.

```elixir
QuackDB.query(MyApp.QuackDB, "SELECT 1", [], timeout: 10_000)
```

For local development, tests, or notebooks, QuackDB can also supervise a local DuckDB Quack server process with MuonTrap:

```elixir
children = [
  {QuackDB.Server,
   name: MyApp.DuckDB,
   endpoint: "quack:localhost:9494",
   uri: "http://[::1]:9494",
   token: System.fetch_env!("QUACKDB_TOKEN")},

  {QuackDB,
   name: MyApp.QuackDB,
   uri: "http://[::1]:9494",
   token: System.fetch_env!("QUACKDB_TOKEN")}
]
```

`QuackDB.Server` starts the external `duckdb` executable and serves the Quack protocol. It is a convenience process supervisor, not an embedded DuckDB driver and not required for remote DuckDB servers.

## Development

```sh
mix deps.get
mix ci
```

Integration tests are skipped by default. To run them against a Quack server:

```sh
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

See [`guides/getting-started.md`](guides/getting-started.md) for a longer walkthrough, [`guides/type-support.md`](guides/type-support.md) for the current DuckDB type matrix, [`guides/examples.md`](guides/examples.md), [`guides/explorer.md`](guides/explorer.md), [`guides/spatial.md`](guides/spatial.md), [`guides/telemetry.md`](guides/telemetry.md), and [`docs/research.md`](docs/research.md) for protocol notes.

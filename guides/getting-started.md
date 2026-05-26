# Getting started

QuackDB connects Elixir applications to a remote DuckDB process through DuckDB's experimental Quack protocol. The client talks to the Quack HTTP endpoint, decodes DuckDB result chunks, and exposes the connection through `DBConnection`.

## Requirements

- Elixir 1.19 or newer
- DuckDB 1.5.3 or newer for the current Quack extension behavior
- A running Quack server

## Install

Add `:quackdb` to your dependencies:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"}
  ]
end
```

Optional integrations are compiled only when their packages are available. Add Explorer when you want dataframe handoff helpers:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"},
    {:explorer, "~> 0.11"}
  ]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

## Start DuckDB with Quack

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

Or start DuckDB manually with the `quack` extension loaded:

```sh
duckdb -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

On some systems, `quack:localhost` binds to IPv6 localhost. If `http://localhost:9494` does not connect, use `http://[::1]:9494`.

## Connect from Elixir

```elixir
{:ok, conn} =
  QuackDB.start_link(
    uri: "http://[::1]:9494",
    token: "super_secret"
  )
```

`QuackDB.start_link/1` starts a `DBConnection` process. You can pass the connection to `QuackDB.ping/2`, `QuackDB.query/4`, `QuackDB.prepare_execute/4`, `QuackDB.stream/4`, or DBConnection APIs.

## Run a query

```elixir
:ok = QuackDB.ping(conn)

{:ok, result} = QuackDB.query(conn, "SELECT 1 AS n")

result.columns
#=> ["n"]

result.rows
#=> [[1]]

result.num_rows
#=> 1
```

`rows` are row-oriented lists. This shape is convenient for DBConnection and future Ecto integration.

QuackDB formats positional parameters as DuckDB SQL literals client-side because the current Quack request path does not expose server-side bind parameters:

```elixir
{:ok, result} = QuackDB.query(conn, "SELECT ? AS name, ? AS n", ["duck", 42])

result.rows
#=> [["duck", 42]]
```

Placeholders inside strings and comments are ignored while formatting, and unsupported parameter values raise explicit errors.

## Decode nested values

DuckDB nested result types decode to ordinary Elixir values:

```elixir
{:ok, result} =
  QuackDB.query(conn, """
  SELECT
    [1, 2, 3] AS xs,
    {'name': 'duck', 'count': 2} AS obj,
    array_value(1, 2, 3) AS arr,
    map(['a', 'b'], [1, 2]) AS m,
    [{'a': 1}, {'a': 2}] AS nested
  """)

result.rows
#=> [
#=>   [
#=>     [1, 2, 3],
#=>     %{"name" => "duck", "count" => 2},
#=>     [1, 2, 3],
#=>     %{"a" => 1, "b" => 2},
#=>     [%{"a" => 1}, %{"a" => 2}]
#=>   ]
#=> ]
```

## Query files and lakehouse sources

DuckDB can scan files, object stores, and lakehouse table formats directly. `QuackDB.Source` builds safe table-function fragments for raw SQL:

```elixir
source =
  QuackDB.Source.parquet("s3://bucket/events/*.parquet",
    hive_partitioning: true,
    union_by_name: true
  )

QuackDB.query!(conn, ["SELECT category, count(*) FROM ", source, " GROUP BY category"])
```

Available helpers include:

- `QuackDB.Source.parquet/2`
- `QuackDB.Source.csv/2`
- `QuackDB.Source.json/2`
- `QuackDB.Source.xlsx/2`
- `QuackDB.Source.delta/2`
- `QuackDB.Source.iceberg/2`

Options are emitted as DuckDB named parameters, and paths/options are formatted as SQL literals instead of interpolated directly:

```elixir
QuackDB.Source.csv("events.csv", header: true, columns: %{id: "INTEGER", name: "VARCHAR"})
#=> "read_csv('events.csv', header = TRUE, columns = {'id': 'INTEGER', 'name': 'VARCHAR'})"
```

The same fragments can be used as Ecto sources for read-oriented analytical queries:

```elixir
source = QuackDB.Source.csv("events.csv", header: true)

MyApp.AnalyticsRepo.all(
  from event in source,
    where: event.id > 1,
    select: %{id: event.id, name: event.name}
)
```

## Stream large result sets

`QuackDB.query/4` materializes the full result. QuackDB fetches additional result chunks when DuckDB reports that more rows are available, but for large analytical results prefer streaming helpers.

Use `QuackDB.stream/4` to process `%QuackDB.Result{}` batches lazily:

```elixir
row_count =
  conn
  |> QuackDB.stream("SELECT i FROM range(0, 50_000) t(i)")
  |> Enum.reduce(0, fn result, count -> count + result.num_rows end)

row_count
#=> 50_000
```

Use `QuackDB.rows/4` for row-level streaming:

```elixir
conn
|> QuackDB.rows("SELECT i FROM range(0, ?) t(i)", [50_000])
|> Enum.take(3)
#=> [[0], [1], [2]]
```

Use `QuackDB.maps/4` for row maps keyed by column names. Duplicate column names are disambiguated with suffixes such as `_2` and `_3`:

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

## Convert results to Explorer DataFrames

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

You can also convert existing results:

```elixir
{:ok, result} = QuackDB.query(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackDB.Explorer.from_result(result)

{:ok, columns} = QuackDB.columnar(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackDB.Explorer.from_columns(columns)
```

## Work with command results

DuckDB returns affected counts as a `Count` result column for DML statements. QuackDB normalizes those into `num_rows`:

```elixir
{:ok, _} = QuackDB.query(conn, "CREATE TEMP TABLE events(id INTEGER)")
{:ok, result} = QuackDB.query(conn, "INSERT INTO events VALUES (1), (2)")

result.command
#=> :insert

result.num_rows
#=> 2

result.columns
#=> nil

result.rows
#=> nil
```

The raw DuckDB count result stays available for debugging:

```elixir
result.metadata[:duckdb_columns]
#=> ["Count"]

result.metadata[:duckdb_rows]
#=> [[2]]
```

## Append rows

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

Native append columns can be declared with scalar `QuackDB.Type` specs and nested specs such as `{:list, :varchar}`, `{:struct, [source: :varchar, count: :integer]}`, `{:array, :integer, 3}`, and `{:map, :varchar, :varchar}`. Temporal append values are normalized through Elixir's Calendar-aware `Date`, `Time`, `NaiveDateTime`, and `DateTime` conversion APIs before encoding.

## Spatial helpers

DuckDB's spatial extension can be loaded with SQL helpers, and spatial expressions can be composed as iodata:

```elixir
alias QuackDB.Spatial

QuackDB.query!(conn, Spatial.load())

point = Spatial.point(1, 2)

QuackDB.query!(conn, [
  "SELECT ",
  point, " AS geom, ",
  Spatial.as_wkb(point), " AS wkb, ",
  Spatial.as_text(point), " AS wkt"
])
```

DuckDB `GEOMETRY` values decode as WKB-compatible bytes. Add optional `{:geo, "~> 4.1"}` when you want to convert those bytes to `Geo` structs with `QuackDB.Geometry.decode_wkb!/1`.

## Inspect output in IEx

QuackDB implements compact inspection for common structs so manual review stays readable:

```elixir
QuackDB.query!(conn, "SELECT i FROM range(0, 4) t(i)")
#QuackDB.Result<command: :select, columns: ["i"], rows: 4, preview: [[0], [1], [2], :...], connection_id: "...", needs_more_fetch?: false>
```

The actual rows are still available through `result.rows`.

## Transactions

QuackDB implements `DBConnection` transaction callbacks with SQL statements:

```elixir
DBConnection.transaction(conn, fn tx ->
  QuackDB.query!(tx, "CREATE TEMP TABLE tx_events(id INTEGER)")
  QuackDB.query!(tx, "INSERT INTO tx_events VALUES (1)")
end)
```

## Ecto raw SQL

QuackDB includes an initial Ecto SQL adapter for raw SQL queries. The Ecto adapter is compiled when `ecto_sql` is available, so add Ecto SQL if your app does not already depend on it:

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

Configure the repo with the same options accepted by `QuackDB.start_link/1`:

```elixir
config :my_app, MyApp.AnalyticsRepo,
  uri: "http://[::1]:9494",
  token: "super_secret"
```

Then run raw SQL through the repo:

```elixir
{:ok, result} = MyApp.AnalyticsRepo.query("SELECT 1 AS n")

result.rows
#=> [[1]]
```

Raw SQL and generated DDL can participate in Ecto transactions:

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

For temporary analytical setup, `QuackDB.DDL.create_table/3` builds quoted DuckDB `CREATE TABLE` statements:

```elixir
MyApp.AnalyticsRepo.query!(
  QuackDB.DDL.create_table("events",
    [payload: :json, occurred_at: :timestamp],
    temporary: true
  )
)
```

Ecto support is analytical rather than CRUD-shaped, but still early. `Repo.query/3`, read-only `Repo.all/2` table queries, and straightforward `Repo.insert_all/3` row inserts work, while migrations, set combinations, locks, updates, deletes, and upserts raise explicit unsupported-feature errors.

## Current limitations

- Server-side bind parameters are not exposed by this Quack client path yet. QuackDB formats supported parameter values as DuckDB SQL literals client-side.
- Native appends support row batches but not Arrow IPC or automatic local-file/data staging yet.
- Ecto support is limited to raw SQL, read-only analytical table queries, and straightforward `insert_all/3` row inserts.
- Quack is experimental and may change with DuckDB releases.

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

The client accepts QuackDB options such as `:uri`, `:token`, and `:transport`, plus DBConnection pool options such as `:name`, `:pool_size`, `:queue_target`, `:queue_interval`, and per-call `:timeout`.

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

## Running QuackDB's integration tests

With a server running locally:

```sh
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

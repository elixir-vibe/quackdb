# QuackDB

[![Hex.pm](https://img.shields.io/hexpm/v/quackdb.svg)](https://hex.pm/packages/quackdb)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/quackdb)

Remote DuckDB Quack protocol client for Elixir.

`quackdb` is a protocol-native client for DuckDB's experimental Quack remote protocol. The client is backed by `DBConnection`, decodes DuckDB result chunks directly, supports streaming/fetching large result sets, and includes an early analytical Ecto adapter for raw SQL and read-oriented queries.

> [!WARNING]
> QuackDB itself is experimental and not production-ready. The package API, result shapes, Ecto adapter behavior, and supported type coverage may change as the project evolves. It also targets DuckDB's experimental Quack protocol, which may change across DuckDB releases. Use it at your own risk, validate behavior against your DuckDB version, and avoid relying on it for critical production workloads yet.

## Status

QuackDB currently focuses on the remote protocol and DBConnection client core. It supports:

- connection handshake over HTTP Quack endpoints
- query execution through `DBConnection`
- streaming and fetch continuation for large results
- common scalar DuckDB types
- nested result values such as `LIST`, `STRUCT`, `ARRAY`, and `MAP`
- source helpers for DuckDB file and lakehouse table functions
- column-oriented result maps for vector-style analytical workflows
- normalized affected-row counts for `INSERT`, `UPDATE`, and `DELETE`
- an early Ecto SQL adapter for `Repo.query/3` and analytical read queries

Raw SQL can use the full DuckDB surface. Ecto query generation is growing toward analytical DuckDB usage while keeping unsupported features explicit.

## Installation

Add `:quackdb` to your dependencies:

```elixir
def deps do
  [
    {:quackdb, "~> 0.1.0"}
  ]
end
```

DuckDB's Quack protocol is currently experimental. For local testing, use DuckDB 1.5.3 or newer with the `quack` extension.

Optional integrations are compiled only when their packages are available. Add Explorer when you want dataframe handoff helpers:

```elixir
def deps do
  [
    {:quackdb, "~> 0.1.0"},
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

You can also convert existing results:

```elixir
{:ok, result} = QuackDB.query(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackDB.Explorer.from_result(result)

{:ok, columns} = QuackDB.columnar(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackDB.Explorer.from_columns(columns)
```

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
    {:quackdb, "~> 0.1.0"},
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

For temporary analytical setup, `QuackDB.DDL.create_table/3` builds quoted DuckDB `CREATE TABLE` statements:

```elixir
MyApp.AnalyticsRepo.query!(
  QuackDB.DDL.create_table("events",
    [payload: :json, occurred_at: :timestamp],
    temporary: true
  )
)
```

Ecto support is analytical rather than CRUD-shaped, but still early. Migrations, set combinations, locks, and Ecto-managed inserts/updates/deletes raise explicit unsupported-feature errors for now.

## Current limitations

- Bind parameters are not exposed through this Quack client path yet.
- Appends are represented at the protocol struct level but are not exposed as public API.
- Ecto support is limited to raw SQL through `Repo.query/3` and read-only analytical table queries through `Repo.all/2`.
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

See [`guides/getting-started.md`](guides/getting-started.md) for a longer walkthrough, [`guides/type-support.md`](guides/type-support.md) for the current DuckDB type matrix, and [`docs/research.md`](docs/research.md) for protocol notes.

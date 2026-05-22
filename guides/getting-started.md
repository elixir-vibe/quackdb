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
    {:quackdb, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

## Start DuckDB with Quack

Start a local DuckDB server with the `quack` extension loaded:

```sh
tail -f /dev/null | duckdb -init /dev/null \
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

Raw SQL can participate in Ecto transactions:

```elixir
{:ok, :committed} =
  MyApp.AnalyticsRepo.transaction(fn ->
    MyApp.AnalyticsRepo.query!("CREATE TEMP TABLE events(id INTEGER)")
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

Simple read-only Ecto queries against table names are also supported, including basic predicates, ordering, limits, aggregates, and fragments:

```elixir
import Ecto.Query

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: event.id > ^min_id and like(event.name, "d%"),
    order_by: [asc: event.id],
    select: %{id: event.id, name: event.name, upper_name: fragment("upper(?)", event.name)}
)
```

The first Ecto milestone is intentionally narrow. `Repo.query/3` and read-only `Repo.all/2` table queries work, while joins, grouped queries, migrations, and Ecto-managed writes raise explicit unsupported-feature errors.

## Current limitations

- Server-side bind parameters are not exposed by this Quack client path yet. QuackDB formats supported parameter values as DuckDB SQL literals client-side.
- Append messages are defined at the protocol layer but not exposed as public API.
- Ecto support is limited to raw SQL through `Repo.query/3` and read-only table queries through `Repo.all/2`.
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

## Running QuackDB's integration tests

With a server running locally:

```sh
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

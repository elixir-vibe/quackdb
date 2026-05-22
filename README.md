# QuackDB

Remote DuckDB Quack protocol client for Elixir.

`quackdb` is a protocol-native client for DuckDB's experimental Quack remote protocol. The client is backed by `DBConnection`, decodes DuckDB result chunks directly, supports streaming/fetching large result sets, and includes an initial Ecto adapter for raw SQL queries.

## Status

QuackDB currently focuses on the remote protocol and DBConnection client core. It supports:

- connection handshake over HTTP Quack endpoints
- query execution through `DBConnection`
- streaming and fetch continuation for large results
- common scalar DuckDB types
- nested result values such as `LIST`, `STRUCT`, `ARRAY`, and `MAP`
- normalized affected-row counts for `INSERT`, `UPDATE`, and `DELETE`
- a minimal Ecto SQL adapter for `Repo.query/3`

Higher-level Ecto schema queries, migrations, and write planning are planned after the raw SQL adapter path is stable.

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

## Start a DuckDB Quack server

```sh
tail -f /dev/null | duckdb -init /dev/null \
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
{:ok, result} = QuackDB.query(conn, "SELECT 1 AS n")

result.columns
#=> ["n"]

result.rows
#=> [[1]]
```

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

### Streaming

Use `QuackDB.stream/4` for large result sets:

```elixir
row_count =
  conn
  |> QuackDB.stream("SELECT i FROM range(0, 50_000) t(i)")
  |> Enum.reduce(0, fn result, count -> count + result.num_rows end)

row_count
#=> 50_000
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

Raw SQL also works inside Ecto transactions:

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

This first Ecto milestone is intentionally limited to raw SQL. Schema queries, migrations, and Ecto-managed inserts/updates/deletes raise explicit unsupported-feature errors for now.

## Current limitations

- Bind parameters are not exposed through this Quack client path yet.
- Appends are represented at the protocol struct level but are not exposed as public API.
- Ecto support is limited to raw SQL through `Repo.query/3`.
- The low-level protocol is experimental and tracks DuckDB's Quack extension behavior.

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

See [`guides/getting-started.md`](guides/getting-started.md) for a longer walkthrough and [`docs/research.md`](docs/research.md) for protocol notes.

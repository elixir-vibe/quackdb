# QuackDB 🦆

[![Hex.pm](https://img.shields.io/hexpm/v/quackdb.svg)](https://hex.pm/packages/quackdb) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/quackdb) [![License](https://img.shields.io/hexpm/l/quackdb.svg)](https://github.com/elixir-vibe/quackdb/blob/master/LICENSE)

DuckDB for Elixir applications. One dependency gives you an OTP-supervised DuckDB process, a DBConnection client, and an Ecto adapter with a query DSL for analytical SQL, speaking DuckDB's Quack protocol.

```elixir
defmodule MyApp.Analytics do
  use QuackDB.Ecto

  alias QuackDB.Source

  # Daily API latency for a month, read straight from the lakehouse,
  # with every day present even when nothing happened.
  def daily_latency(month) do
    events = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)

    query =
      from day in series(month),
        left_join: event in ^events,
        on: event.occurred_on == day.value and regexp_matches(event.path, ~r"^/api/"),
        group_by: day.value,
        order_by: day.value,
        select: %{
          day: day.value,
          requests: count(event.id),
          errors: filter(count(event.id), event.status >= 500),
          p95_ms: quantile_cont(event.duration_ms, 0.95),
          slowest: arg_max(event.path, event.duration_ms)
        }

    QuackDB.Explorer.dataframe!(MyApp.AnalyticsRepo, query)
  end
end

MyApp.Analytics.daily_latency(Date.range(~D[2024-01-01], ~D[2024-01-31]))
#=> #Explorer.DataFrame<
#     Polars[31 x 5]
#     day date [2024-01-01, 2024-01-02, 2024-01-03, ...]
#     errors s64 [1, 0, 0, ...]
#     p95_ms f64 [861.0, nil, 300.0, ...]
#     requests s64 [2, 0, 1, ...]
#     slowest string ["/api/users", nil, "/api/orders", ...]
#   >
```

A `Date.Range` is a calendar source, a Parquet glob on S3 is a table, the regex is an Elixir sigil that runs as RE2, `filter` and `arg_max` are the aggregates plain Ecto lacks, and the result is a dataframe. None of it is a string, and this exact query runs in the test suite against a real DuckDB.

## Why QuackDB

DuckDB is already excellent at analytical SQL. QuackDB does the Elixir side properly: DuckDB runs as a supervised child of your application, connections are pooled through DBConnection with transactions and streams, and the queries you would otherwise assemble as SQL strings compose as Ecto queries with DuckDB's own functions, sources, and extensions available as macros.

Values stay Elixir-native: `Duration` steps for series, `%Geo.*{}` structs for spatial, `Date.Range` for calendars, maps and lists for `STRUCT`, `MAP`, and `LIST`, Explorer dataframes in and out, and Explorer's `:nan`, `:infinity`, and `:neg_infinity` for the floats the BEAM cannot represent. Anything DuckDB can decode but QuackDB cannot represent raises an explicit error rather than a lossy value.

You never have to write SQL. What Ecto queries do not model has an Elixir builder: `QuackDB.DDL` for tables, sequences, `CREATE TABLE AS`, and inline checks; `QuackDB.DML` for inserts, `INSERT ... SELECT`, deletes, and `MERGE INTO`; `QuackDB.SQL` for `PIVOT`, `UNPIVOT`, `GROUPING SETS`, `ROLLUP`, `CUBE`, `EXPLAIN`, and settings; `QuackDB.Analytics` for `SUMMARIZE`; `QuackDB.FTS`, `Source`, `Secret`, and `Extension` for the extensions. Every builder returns iodata with parameters kept separate, so it runs through the same pooled sessions and telemetry as a query. A SQL string is accepted wherever a builder is, for the day you want one.

| Elixir layer | What QuackDB adds |
| --- | --- |
| OTP | supervised local DuckDB server, managed binary, restartable child specs |
| DBConnection | pooled Quack sessions, queries, streams, transactions |
| Ecto | adapter, query DSL, analytical helpers, migrations, writes |
| Explorer | dataframe append and dataframe-friendly results |
| Geo | `%Geo.*{}` params and WKB/GeoJSON workflows |
| Table.Reader | Livebook and dataframe-friendly result consumption |
| Telemetry | query, append, and fetch spans |
| Mix | `quackdb.install` task for managed DuckDB binaries |

## Installation

```elixir
def deps do
  [
    {:quackdb, "~> 0.5.25"}
  ]
end
```

Optional integrations light up when their packages are present:

```elixir
{:ecto_sql, "~> 3.13"},   # Ecto adapter, query DSL, migrations
{:explorer, "~> 0.11"},   # dataframe append and results
{:geo, "~> 4.1"}          # %Geo.*{} spatial values
```

QuackDB needs DuckDB 1.5.5 or newer with the `quack` extension. With `duckdb: :managed` it downloads and verifies DuckDB's official CLI binary on first start, so nothing else has to be installed.

## Quick start

Add DuckDB and a Repo to your supervision tree:

```elixir
children =
  QuackDB.Server.child_specs(
    server: [name: MyApp.DuckDB, duckdb: :managed, database: "analytics.duckdb"],
    client: {MyApp.AnalyticsRepo, pool_size: 2}
  )

Supervisor.start_link(children, strategy: :rest_for_one)
```

```elixir
defmodule MyApp.AnalyticsRepo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.QuackDB
end
```

`child_specs/1` generates one token and injects the matching URI and token into both children. Then query:

```elixir
MyApp.AnalyticsRepo.query!("SELECT 42 AS answer").rows
#=> [[42]]

MyApp.AnalyticsRepo.all(MyApp.Analytics.category_latency())
```

Without Ecto, the DBConnection client works on its own:

```elixir
{:ok, conn} = QuackDB.start_link(uri: "http://[::1]:9494", token: "super_secret")
{:ok, result} = QuackDB.query(conn, "SELECT ? AS name, ? AS n", ["duck", 42])
result.rows
#=> [["duck", 42]]
```

See [Getting started](https://hexdocs.pm/quackdb/getting-started.html) and [Managed DuckDB](https://hexdocs.pm/quackdb/managed-duckdb.html).

## Queries

`use QuackDB.Ecto` imports DuckDB's analytical aggregates, date and timestamp series, text and RE2 regex predicates, list, map, and struct helpers, window frames, and conditionals as macros that compose with ordinary Ecto queries:

```elixir
from day in series(Date.range(~D[2024-01-01], ~D[2024-01-31])),
  left_join: event in "events",
  on: event.occurred_on == day.value,
  group_by: day.value,
  select: %{day: day.value, events: count(event.id), slow: filter(count(event.id), event.duration_ms > 1_000)}
```

Sources are Ecto sources too: `Source.parquet/2`, `Source.csv/2`, `Source.json/2`, and lakehouse catalogs can be queried where the data already lives, and materialized with `QuackDB.DDL.create_table(as: query)` when you want an index on them.

See the [Ecto guide](https://hexdocs.pm/quackdb/ecto.html), [Sources](https://hexdocs.pm/quackdb/sources.html), [Full-text search](https://hexdocs.pm/quackdb/full-text-search.html), and [Spatial](https://hexdocs.pm/quackdb/spatial.html).

## Statements as Elixir

DDL, DML, and DuckDB's statement-level extensions are Elixir data, not strings:

```elixir
alias QuackDB.{DDL, DML, FTS, SQL, Source}

Repo.query!(DDL.create_table("docs", as: from(d in Source.parquet("s3://bucket/docs/*.parquet"), select: %{id: d.id, body: d.body})))
Repo.query!(FTS.create_index("docs", :id, [:body], overwrite: true))
Repo.query!(SQL.pivot(:events, on: :kind, using: [sum: :n]))

{sql, params} = DML.delete_from(:events, where: [kind: "test", day: day])
Repo.query!(sql, params)
```

## Writes

Rows, columns, Explorer dataframes, `Table.Reader` data, and streams go in through DuckDB's native append protocol instead of generated `INSERT` statements:

```elixir
QuackDB.insert_rows!(conn, "events", [[id: 1, name: "duck", tags: ["bird", "wetland"]]])

File.stream!("events.ndjson")
|> Stream.map(&Jason.decode!/1)
|> QuackDB.insert_stream!(MyApp.AnalyticsRepo, "events", chunk_every: 10_000)

MyApp.AnalyticsRepo.insert_all(MyApp.Event, rows, insert_method: :append)
```

See the [Writes guide](https://hexdocs.pm/quackdb/writes.html) and [Explorer](https://hexdocs.pm/quackdb/explorer.html).

## Results and observability

`QuackDB.Result` implements `Table.Reader`, so results drop into Livebook, `Explorer.DataFrame.new/1`, and VegaLite as they are. Telemetry spans cover every query, append, and fetch; `QuackDB.Profile` returns DuckDB's own operator timings; `QuackDB.Storage` and `QuackDB.Meta` expose storage and catalog metadata as structs.

See [Observability](https://hexdocs.pm/quackdb/observability.html) and [Telemetry](https://hexdocs.pm/quackdb/telemetry.html).

## Ecto coverage

The adapter covers schema reads and writes, `insert_all` with upserts and `RETURNING`, `update_all` and `delete_all`, transactions, `explain`, and migrations with tables, columns, references, indexes, primary keys, and check constraints. It targets analytical workloads and states its limits explicitly; the [coverage matrix](https://hexdocs.pm/quackdb/ecto-analytical-coverage.html) lists every construct and its status.

## Documentation

Guides, the type support reference, protocol coverage, and runnable [examples](https://github.com/elixir-vibe/quackdb/tree/master/examples) on [HexDocs](https://hexdocs.pm/quackdb).

## Part of Elixir Vibe

QuackDB gives Elixir applications an OTP-supervised DuckDB with an Ecto adapter — the local-first analytics store the stack's memory lives in.

It is one building block of a larger stack — tools that make AI-generated
software checkable: structural search, dependence analysis, duplication and
slop detection, session replay, and ecosystem-wide code search. See the
[Elixir Vibe](https://github.com/elixir-vibe) organization for the rest, and
[Building Blocks for the Future Web](https://github.com/elixir-vibe/building-blocks)
for the thesis, architecture, and roadmap that tie them together.

## License

MIT © 2026 Danila Poyarkov

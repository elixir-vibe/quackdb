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

## How QuackDB fits together

```text
Elixir application
  ├─ QuackDB / DBConnection query and stream APIs
  ├─ Ecto adapter, analytics helpers, and spatial query DSL
  ├─ Explorer dataframe helpers and native dataframe append
  ├─ Table.Reader support for Livebook and Table-aware tooling
  ├─ Geo bridge for DuckDB GEOMETRY WKB bytes
  ├─ Telemetry spans for query, append, and fetch operations
  ├─ SQL helpers for extensions, sources, DDL, DML, and DuckDB secrets
  └─ QuackDB.Server for local DuckDB supervision in demos/tests
        │
        ▼
DuckDB + quack extension
```

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
children =
  QuackDB.Server.child_specs(
    server: [name: MyApp.DuckDB, duckdb: :managed, endpoint: "quack:localhost:9494"],
    client: [name: MyApp.QuackDB, pool_size: System.schedulers_online()]
  )
```

`child_specs/1` generates one shared random token and injects the matching URI/token into both child specs. Pass `:token` on either side when you want to provide it yourself. `duckdb: :managed` downloads and caches DuckDB's official CLI binary on first use.

Or start DuckDB manually:

```sh
duckdb -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

`quack:localhost` may bind on IPv6 localhost, so the examples use `http://[::1]:9494`.

## Usage

Connect and run a query:

```elixir
{:ok, conn} =
  QuackDB.start_link(
    uri: "http://[::1]:9494",
    token: "super_secret"
  )

{:ok, result} = QuackDB.query(conn, "SELECT ? AS name, ? AS n", ["duck", 42])

result.columns
#=> ["name", "n"]

result.rows
#=> [["duck", 42]]
```

QuackDB provides a few layers that can be used independently:

| Layer | Use it for | Start here |
| --- | --- | --- |
| `QuackDB.query/4`, streams, and columnar helpers | Direct DBConnection-style analytical queries | [`guides/getting-started.md`](guides/getting-started.md) |
| `QuackDB.Source` | DuckDB file, object-store, and lakehouse table functions | [`guides/sources.md`](guides/sources.md) |
| `QuackDB.insert_rows/4` and `insert_columns/4` | Native Quack append protocol writes | [`guides/getting-started.md#append-rows`](guides/getting-started.md#append-rows) |
| `Ecto.Adapters.QuackDB` and `use QuackDB.Ecto` | Ecto SQL queries, analytics helpers, spatial fragments, and plain inserts | [`guides/getting-started.md#ecto-raw-sql`](guides/getting-started.md#ecto-raw-sql) |
| `QuackDB.Explorer` and `Table.Reader` | DataFrame conversion, dataframe append, and Livebook-friendly tabular output | [`guides/explorer.md`](guides/explorer.md) |
| `QuackDB.Spatial`, `QuackDB.Ecto.Spatial`, and `QuackDB.Geometry` | DuckDB Spatial SQL, Ecto spatial queries, and optional Geo/WKB conversion | [`guides/spatial.md`](guides/spatial.md) |
| Telemetry spans | Query, append, and fetch spans | [`guides/telemetry.md`](guides/telemetry.md) |
| `QuackDB.Secret` and `QuackDB.Extension.install/1` / `load/1` | DuckDB extensions and secrets for HTTP/S3/R2/GCS/Azure/Hugging Face sources | [`guides/sources.md`](guides/sources.md) |

A few common snippets:

```elixir
import Ecto.Query

alias QuackDB.{Extension, Secret, Source}

# DuckDB extensions and secrets
QuackDB.query!(conn, Extension.install(:httpfs))
QuackDB.query!(conn, Extension.load(:httpfs))
QuackDB.query!(conn, Secret.create(:s3, provider: :credential_chain))

# Source helpers with Ecto
source = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)

MyApp.AnalyticsRepo.all(
  from event in source,
    group_by: event.category,
    select: %{category: event.category, events: count()}
)

# Native append
QuackDB.insert_rows!(conn, "events", [
  [id: 1, name: "duck"],
  [id: 2, name: "goose"]
])

# Ecto query helpers
defmodule MyApp.Analytics do
  use QuackDB.Ecto

  def query(min_id) do
    from event in "events",
      where: event.id > ^min_id,
      group_by: event.category,
      select: %{category: event.category, median_score: median(event.score)}
  end
end
```

For a full walkthrough, use [`guides/getting-started.md`](guides/getting-started.md). The README intentionally stays short so feature-specific guides remain the source of truth.

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
children =
  QuackDB.Server.child_specs(
    server: [
      name: MyApp.DuckDB,
      duckdb: :managed,
      endpoint: "quack:localhost:9494",
      settings: [threads: System.schedulers_online()],
      global_settings: [quack_fetch_batch_chunks: 4]
    ],
    client: [name: MyApp.QuackDB, pool_size: System.schedulers_online()]
  )
```

`QuackDB.Server` starts the external `duckdb` executable and serves the Quack protocol. QuackDB does not download DuckDB during dependency compilation; use `duckdb: :managed` or the install Mix task when you want QuackDB to download and cache DuckDB's official CLI binary. Managed downloads are checksum-verified for QuackDB's pinned DuckDB version. Set `QUACKDB_BINARY_PATH` or pass `duckdb: "/path/to/duckdb"` when you want to control the executable. See the [managed DuckDB guide](guides/managed-duckdb.md) for cache, checksum, and target-prefetch options. By default it sets DuckDB `threads` to `System.schedulers_online()` and lowers `quack_fetch_batch_chunks` from DuckDB's default `12` to `4`, which keeps fetch responses smaller while still batching chunks. For heavy analytical scans, use a smaller client `pool_size` such as `1..4`; for many small concurrent queries, use `System.schedulers_online()`.

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

See [`guides/getting-started.md`](guides/getting-started.md) for a longer walkthrough, [`guides/type-support.md`](guides/type-support.md) for the current DuckDB type matrix, [`guides/examples.md`](guides/examples.md), [`guides/explorer.md`](guides/explorer.md), [`guides/sources.md`](guides/sources.md), [`guides/spatial.md`](guides/spatial.md), [`guides/telemetry.md`](guides/telemetry.md), and [`docs/protocol-coverage.md`](docs/protocol-coverage.md) for protocol notes.

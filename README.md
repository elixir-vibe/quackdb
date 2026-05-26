# QuackDB

[![Hex.pm](https://img.shields.io/hexpm/v/quackdb.svg)](https://hex.pm/packages/quackdb)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/quackdb)

QuackDB is an Elixir client for remote DuckDB analytics over DuckDB's experimental Quack protocol.

It gives Elixir applications a `DBConnection`-first way to query, stream from, and append to DuckDB without embedding DuckDB inside the BEAM. Use it directly for analytical SQL, add Ecto when you want query composition and migrations, hand results to Explorer or Livebook, and let QuackDB supervise a local DuckDB server for development and notebooks.

> [!WARNING]
> QuackDB targets DuckDB's experimental Quack protocol and is not production-ready yet. Public APIs, result shapes, Ecto adapter behavior, and supported protocol coverage may still change as DuckDB and QuackDB evolve. Validate behavior against your DuckDB version before relying on it for critical workloads.

## What you can build with it

QuackDB is useful when your Elixir system needs DuckDB's analytical engine, but you want DuckDB to live as a separate process:

- local analytics services backed by DuckDB files;
- Livebook and Explorer workflows with supervised DuckDB;
- ingestion pipelines that append row, column, or dataframe batches;
- Ecto-powered analytical queries and setup migrations;
- spatial data exploration with DuckDB Spatial and optional Geo/WKB conversion;
- full-text search over DuckDB tables with BM25 ranking;
- querying Parquet, CSV, JSON, XLSX, Delta, and Iceberg sources from local paths or object stores.

## Highlights

| Area | What QuackDB provides |
| --- | --- |
| Core client | `DBConnection` process per Quack session, persistent Mint transport, query/fetch/stream APIs |
| Results | Row results, column helpers, `Table.Reader` support, Livebook-friendly tabular output |
| Writes | Native Quack append protocol via `insert_rows/4`, `insert_columns/4`, Explorer dataframe append, Ecto SQL inserts/upserts |
| Ecto | Adapter for raw SQL, analytical reads, full schema selects, inserts/upserts, update/delete, basic migrations, `Repo.explain`, transactions |
| Sources | Helpers for DuckDB table functions: CSV, Parquet, JSON, XLSX, Delta, Iceberg, plus HTTP/S3/R2/GCS/Azure/Hugging Face secrets |
| Spatial | DuckDB Spatial helpers, Ecto spatial fragments, WKB bytes, optional `%Geo.*{}` conversion |
| Full-text search | DuckDB FTS extension helpers for index management, BM25 ranking, stemming, and Ecto search expressions |
| Local server | Supervised DuckDB CLI process, shared client/server token setup, optional managed DuckDB binary download/cache |
| Observability | Telemetry spans for query, append, and fetch operations, including client query IDs |
| Protocol | Direct Quack decoding, streaming fetch continuation, scalar/nested type coverage, quack-ts fixture conformance |

## Installation

Add QuackDB to your dependencies:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"}
  ]
end
```

Optional integrations are enabled when their packages are present:

```elixir
def deps do
  [
    {:quackdb, "~> 0.2.0"},
    {:ecto_sql, "~> 3.13"},
    {:explorer, "~> 0.11"},
    {:geo, "~> 4.1"}
  ]
end
```

DuckDB's Quack protocol is experimental. For local development, use DuckDB 1.5.3 or newer with the `quack` extension.

## Quick start with a supervised local DuckDB

For development, tests, examples, and notebooks, QuackDB can supervise DuckDB's CLI process and start a matching client pool. `child_specs/1` generates one random token and injects it into both children.

```elixir
children =
  QuackDB.Server.child_specs(
    server: [
      name: MyApp.DuckDB,
      duckdb: :managed,
      endpoint: "quack:localhost:9494"
    ],
    client: [
      name: MyApp.QuackDB,
      pool_size: System.schedulers_online()
    ]
  )
```

`duckdb: :managed` downloads DuckDB's official CLI binary on first use, verifies known checksums for QuackDB's pinned DuckDB version, and caches it. QuackDB never downloads DuckDB during dependency compilation. Use `QUACKDB_BINARY_PATH`, `QUACKDB_BINARY_CACHE_DIR`, `duckdb: "/path/to/duckdb"`, or run the `quackdb.install` Mix task when you want explicit control. See the [managed DuckDB guide](guides/managed-duckdb.md).

You can also start DuckDB manually:

```sh
duckdb -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

`quack:localhost` often binds on IPv6 localhost, so examples use `http://[::1]:9494`.

## Direct queries

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

Use `QuackDB.stream/4` for large result sets, or `QuackDB.columns/4` when a column-oriented shape is more convenient for analytics tooling.

## Native append writes

QuackDB can write through DuckDB's native append protocol instead of generating huge `INSERT VALUES` statements.

```elixir
QuackDB.insert_rows!(conn, "events", [
  [id: 1, name: "duck", tags: ["bird", "wetland"]],
  [id: 2, name: "goose", tags: ["bird", "loud"]]
])

QuackDB.insert_columns!(conn, "measurements", [
  id: [1, 2, 3],
  temperature: [12.5, 13.0, 12.8]
])
```

Append supports explicit types, batching, scalar DuckDB values, and nested `LIST`, `STRUCT`, `ARRAY`, and `MAP` values. Explorer dataframes can be appended with `QuackDB.Explorer.insert_dataframe/4` when Explorer is installed.

## Ecto adapter

QuackDB includes an optional Ecto SQL adapter for applications that want Ecto query composition, schema-based reads/writes, migrations, and raw SQL through `Repo.query/3`.

```elixir
defmodule MyApp.AnalyticsRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

```elixir
import Ecto.Query

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: event.score > ^10,
    group_by: event.category,
    select: %{category: event.category, events: count()}
)
```

For DuckDB-specific analytical helpers, spatial fragments, and normal Ecto query imports together:

```elixir
defmodule MyApp.Analytics do
  use QuackDB.Ecto

  def median_scores do
    from event in "events",
      group_by: event.category,
      select: %{category: event.category, median_score: median(event.score)}
  end
end
```

The adapter currently covers:

- raw SQL via `Repo.query/3`;
- schema-backed full selects and `Repo.get!/2`;
- analytical reads with joins, filters, grouping, windows, CTEs, combinations, locks, and fragments;
- `Repo.insert/2`, `Repo.insert_all/3`, `RETURNING`, `ON CONFLICT DO NOTHING`, and common `DO UPDATE` upserts;
- explicit native append fast path via `insert_method: :append`;
- `update_all`, `delete_all`, schema `update/delete`, and transaction usage;
- `Ecto.Adapters.SQL.explain/4`;
- basic migration DDL through Ecto migrator: create/drop/alter tables, columns, references, indexes, primary keys, check constraints, and renames.

DuckDB-specific SQL that Ecto cannot model cleanly should still use `Repo.query/3`. See the [Ecto coverage matrix](docs/ecto-analytical-coverage.md).

## Query files, object stores, and lakehouse tables

DuckDB can query data where it lives. QuackDB provides small helpers that generate DuckDB table-function SQL while leaving credentials and file access to DuckDB.

```elixir
alias QuackDB.{Extension, Secret, Source}

QuackDB.query!(conn, Extension.install(:httpfs))
QuackDB.query!(conn, Extension.load(:httpfs))
QuackDB.query!(conn, Secret.create(:s3, provider: :credential_chain))

source = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)

MyApp.AnalyticsRepo.all(
  from event in source,
    group_by: event.category,
    select: %{category: event.category, events: count()}
)
```

QuackDB does not upload local files for you. The DuckDB server must be able to see the path, URL, object store, or lakehouse catalog. See the [sources guide](guides/sources.md).

## Spatial workflows

DuckDB Spatial works well through raw SQL, QuackDB expression helpers, or Ecto fragments.

```elixir
alias QuackDB.Spatial

QuackDB.query!(conn, Spatial.install())
QuackDB.query!(conn, Spatial.load())

QuackDB.query!(conn, [
  "SELECT ",
  Spatial.as_geojson(Spatial.point(13.405, 52.52)),
  " AS berlin"
])
```

`GEOMETRY` values decode as WKB-compatible bytes for tested DuckDB Spatial values. `QuackDB.Geometry` can convert to/from `%Geo.*{}` structs when the optional `:geo` package is installed. See the [spatial guide](guides/spatial.md).

## Full-text search

DuckDB's FTS extension can index text columns and rank matches with BM25. QuackDB wraps the setup pragmas and search expressions:

```elixir
alias QuackDB.FTS

QuackDB.query!(conn, FTS.install())
QuackDB.query!(conn, FTS.load())
QuackDB.query!(conn, FTS.create_index("documents", :id, [:title, :body], overwrite: true))

score = FTS.match_bm25(~s|"id"|, "duckdb analytics", schema: FTS.schema_name("main.documents"))
QuackDB.query!(conn, ["SELECT id, title, ", score, " AS score FROM documents ORDER BY score DESC"])
```

Use `QuackDB.Ecto.FTS` or `use QuackDB.Ecto` for Ecto query expressions. See the [full-text search guide](guides/full-text-search.md).

## Explorer, Table.Reader, and Livebook

When Explorer is installed, QuackDB can move data between DuckDB and dataframes:

```elixir
alias Explorer.DataFrame
alias QuackDB.Explorer, as: QuackExplorer

frame = DataFrame.new(id: [1, 2], name: ["duck", "goose"])
QuackExplorer.insert_dataframe!(conn, "events", frame)

result = QuackDB.query!(conn, "SELECT * FROM events")
DataFrame.new(result)
```

`QuackDB.Result` and `QuackDB.Columns` implement `Table.Reader`, so they can be consumed by Livebook and other Table-aware tooling. See the [Explorer guide](guides/explorer.md) and the [Livebook example](https://github.com/elixir-vibe/quackdb/blob/master/examples/livebook_analytics.livemd).

## Observability

QuackDB emits telemetry spans for query, append, and fetch operations:

- `[:quackdb, :query, :start | :stop]`
- `[:quackdb, :append, :start | :stop]`
- `[:quackdb, :fetch, :start | :stop]`

Metadata includes connection/session information, command details, append batch counts, and client query IDs. Params are not included unless you opt in with `telemetry_params: true`. See the [telemetry guide](guides/telemetry.md).

## Architecture

```text
Elixir application
  ├─ QuackDB / DBConnection query and stream APIs
  ├─ Ecto adapter, analytics helpers, and migration DDL
  ├─ Native row, column, and dataframe append APIs
  ├─ Explorer and Table.Reader integrations
  ├─ Spatial helpers and optional Geo/WKB bridge
  ├─ Source, extension, secret, DDL, and DML SQL helpers
  ├─ Telemetry spans and client query IDs
  └─ QuackDB.Server for local DuckDB supervision
        │
        ▼
DuckDB + quack extension
```

Each DBConnection process owns one Quack session and one persistent Mint HTTP connection. This matches Quack's sessionful protocol: prepared statements, fetch cursors, append requests, and disconnect messages all belong to a DuckDB connection id.

For local supervised DuckDB, QuackDB defaults to performance-conscious settings:

```elixir
settings: [threads: System.schedulers_online()],
global_settings: [quack_fetch_batch_chunks: 4]
```

For heavy analytical scans, prefer a smaller client `pool_size` such as `1..4` because DuckDB parallelizes internally. For many small concurrent queries, `System.schedulers_online()` is a reasonable starting point.

## Type and protocol coverage

QuackDB decodes common DuckDB scalars and nested values, including:

- booleans and integers through huge integers;
- floats and decimals;
- UUID, enum, blob, varchar, bit, and `BIGNUM`;
- date/time/timestamp families, including nanosecond values and `TIME WITH TIME ZONE`;
- intervals;
- `LIST`, `STRUCT`, `ARRAY`, and `MAP`;
- DuckDB Spatial `GEOMETRY` as WKB-compatible bytes.

The protocol implementation is intentionally explicit about unsupported features. Remaining low-level gaps, conformance fixtures, and unsupported vector/logical types are tracked in [`docs/protocol/coverage.md`](docs/protocol/coverage.md) and [`guides/type-support.md`](guides/type-support.md).

## Examples

The repository includes runnable scripts and a Livebook notebook:

- [`examples/query_observability.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/query_observability.exs) — attach telemetry handlers and print query, append, and fetch timings.
- [`examples/dataframe_analytics.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/dataframe_analytics.exs) — derive DDL from an Ecto schema, append an Explorer dataframe, query with Ecto DSL, and return a dataframe.
- [`examples/livebook_analytics.livemd`](https://github.com/elixir-vibe/quackdb/blob/master/examples/livebook_analytics.livemd) — interactive analytics with DuckDB SQL, Explorer, Table.Reader, VegaLite, and telemetry.
- [`examples/spatial_wms/`](https://github.com/elixir-vibe/quackdb/tree/master/examples/spatial_wms) — a minimal Ash + Ecto + Plug/Bandit app serving DuckDB Spatial rows through a WMS-like GeoJSON endpoint.
- [`examples/append_benchmark.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/append_benchmark.exs) — compares SQL inserts, native row/column append, Explorer append, and Ecto insert paths.
- [`examples/support/quackdb_demo.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/support/quackdb_demo.exs) — shared demo boot helper that starts `QuackDB.Server` unless `QUACKDB_URI` is set.

Run scripts from outside the Mix project so `Mix.install/2` can load the local package:

```sh
cd /tmp
elixir /path/to/quackdb/examples/dataframe_analytics.exs
```

## Current boundaries

QuackDB is already broad, but intentionally not a complete DuckDB or Postgrex replacement:

- the Quack wire protocol is experimental and may change;
- unsupported vector/logical types raise explicit protocol errors;
- Ecto coverage focuses on analytical workflows and common write/setup paths, not every relational adapter feature;
- QuackDB does not stage/upload local files to a remote server;
- Arrow IPC / zero-copy columnar handoff is research for now;
- managed DuckDB binary downloads currently cover Linux/macOS targets, not Windows.

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

Useful docs:

- [Getting started](guides/getting-started.md)
- [Type support](guides/type-support.md)
- [Examples](guides/examples.md)
- [Managed DuckDB](guides/managed-duckdb.md)
- [Explorer](guides/explorer.md)
- [Sources](guides/sources.md)
- [Spatial](guides/spatial.md)
- [Full-text search](guides/full-text-search.md)
- [Telemetry](guides/telemetry.md)
- [Protocol coverage](docs/protocol/coverage.md)
- [Ecto coverage](docs/ecto-analytical-coverage.md)

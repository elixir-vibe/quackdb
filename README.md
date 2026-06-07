# QuackDB

[![Hex.pm](https://img.shields.io/hexpm/v/quackdb.svg)](https://hex.pm/packages/quackdb)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/quackdb)

DuckDB for Elixir applications, over DuckDB's experimental Quack protocol.

QuackDB gives Elixir applications an OTP-supervised DuckDB process, a DBConnection client, an Ecto adapter and query DSL for analytical DuckDB workflows, native append APIs, Explorer dataframe writes, Geo/WKB spatial integration, Table.Reader results, telemetry, and a managed DuckDB binary installer.

> [!WARNING]
> QuackDB targets DuckDB's experimental Quack protocol and is not production-ready yet. Public APIs, result shapes, Ecto adapter behavior, and supported protocol coverage may still change as DuckDB and QuackDB evolve. Validate behavior against your DuckDB version before relying on it for critical workloads.

```elixir
defmodule MyApp.Analytics do
  use QuackDB.Ecto

  alias QuackDB.Source

  def category_latency do
    source = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)

    from event in source,
      group_by: event.category,
      select: %{
        category: event.category,
        p95: quantile_cont(event.duration_ms, 0.95),
        median: median(event.duration_ms),
        events: count()
      }
  end
end
```

## Why QuackDB?

DuckDB is already excellent at analytical SQL. QuackDB focuses on the Elixir side:

- run DuckDB as a supervised process during development, tests, notebooks, examples, or local apps;
- use DBConnection semantics for pooled sessions, transactions, streams, and query lifecycle;
- compose DuckDB analytical queries with Ecto instead of assembling SQL strings;
- use Elixir-native values such as `Duration`, `%Geo.*{}`, `Date.Range`, maps, lists, structs, and Explorer dataframes where possible;
- append rows, columns, and Explorer dataframes through DuckDB's native append path;
- expose results to Livebook and dataframe tooling through `Table.Reader`;
- keep raw SQL available when DuckDB-specific syntax is clearer or not represented by Ecto.

## Elixir integrations

| Elixir layer | QuackDB integration |
| --- | --- |
| OTP | supervised local DuckDB server, managed binary, restartable child specs |
| DBConnection | pooled Quack sessions, queries, streams, transactions |
| Ecto | adapter, query DSL, analytical helpers, migrations, writes |
| Explorer | dataframe append and dataframe-friendly results |
| Geo | `%Geo.*{}` params and WKB/GeoJSON workflows |
| Table.Reader | Livebook/dataframe-friendly result consumption |
| Telemetry | query, append, and fetch spans |
| Mix | `quackdb.install` task for managed DuckDB binaries |

## Installation

Add QuackDB to your dependencies:

```elixir
def deps do
  [
    {:quackdb, "~> 0.3.0"}
  ]
end
```

Optional integrations are enabled when their packages are present:

```elixir
def deps do
  [
    {:quackdb, "~> 0.3.0"},
    {:ecto_sql, "~> 3.13"},
    {:explorer, "~> 0.11"},
    {:geo, "~> 4.1"}
  ]
end
```

DuckDB's Quack protocol is experimental. For local development, use DuckDB 1.5.3 or newer with the `quack` extension.

## Supervised DuckDB

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

For rebuildable local artifacts, attach the persistent database with DuckDB's no-WAL recovery mode:

```elixir
children =
  QuackDB.Server.child_specs(
    server: [
      duckdb: :managed,
      database: "priv/index.duckdb",
      recovery_mode: :no_wal_writes,
      settings: [threads: 8]
    ],
    client: [name: MyApp.QuackDB]
  )
```

`recovery_mode: :no_wal_writes` starts DuckDB in memory, attaches the database with `ATTACH ... (RECOVERY_MODE no_wal_writes)`, and then starts `quack_serve/2`. Use it only for databases that can be rebuilt if the process exits before data is durable.

You can also start DuckDB manually:

```sh
duckdb -csv -noheader -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

`quack:localhost` often binds on IPv6 localhost, so examples use `http://[::1]:9494`. The supervised server detects readiness from the `quack_serve` result row printed by the DuckDB CLI and falls back to HTTP probes for custom daemon commands or output handling.

## DBConnection client

QuackDB can be used directly through its DBConnection-backed client.

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

Use `QuackDB.rows/4` or `QuackDB.maps/4` to stream large row-shaped results. Use `QuackDB.columnar_batches/4` or `QuackDB.column_batches/4` when analytics code can work with column-oriented batches without materializing the full result set.

## DuckDB workflows as Ecto queries

QuackDB exposes common DuckDB analytical workflows as Ecto-compatible helpers so they compose with normal queries.

### Analytical aggregates

```elixir
defmodule MyApp.Analytics do
  use QuackDB.Ecto

  def category_scores do
    from event in "events",
      group_by: event.category,
      select: %{
        category: event.category,
        p95: quantile_cont(event.duration_ms, 0.95),
        median: median(event.duration_ms),
        precise_sum: fsum(event.duration_ms),
        mode: mode(event.duration_ms),
        weighted_average: weighted_avg(event.duration_ms, event.weight),
        values: list(event.duration_ms, order_by: [desc_nulls_last: event.duration_ms]),
        slow_events: filter(count(event.id), event.duration_ms > 1_000),
        distinct_users: count(event.user_id, :distinct),
        average_duration: coalesce(avg(event.duration_ms), 0),
        events: count()
      }
  end
end
```

### Date and timestamp series

```elixir
use QuackDB.Ecto

from day in series(Date.range(~D[2024-01-01], ~D[2024-01-31])),
  left_join: event in "events",
  on: event.occurred_on == day.value,
  group_by: day.value,
  order_by: day.value,
  select: %{
    day: day.value,
    events: count(event.id)
  }
```

Timestamp series use `Duration` steps:

```elixir
from bucket in series(
       ~N[2024-01-01 00:00:00],
       ~N[2024-01-02 00:00:00],
       step: Duration.new!(hour: 1)
     ),
  select: bucket.value
```

### Source scans

DuckDB can query data where it already lives. QuackDB source helpers can be used directly as Ecto sources.

```elixir
use QuackDB.Ecto

alias QuackDB.Source

source = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)

from event in source,
  group_by: event.category,
  select: %{
    category: event.category,
    events: count(),
    avg_score: avg(event.score)
  }
```

QuackDB does not upload local files for you. The DuckDB server must be able to see the path, URL, object store, or lakehouse catalog. See the [sources guide](guides/sources.md).

### CTAS and full-text search

External data can be materialized with `CREATE TABLE AS`, indexed with DuckDB FTS, and queried with BM25 from Ecto.

```elixir
use QuackDB.Ecto

alias QuackDB.{DDL, FTS, Source}

query =
  from doc in Source.parquet("s3://bucket/docs/*.parquet"),
    select: %{
      id: doc.id,
      title: doc.title,
      body: doc.body
    }

MyApp.AnalyticsRepo.query!(DDL.create_table("docs", as: query, temporary: true))
MyApp.AnalyticsRepo.query!(FTS.create_index("docs", :id, [:title, :body], overwrite: true))

schema = FTS.schema_name("main.docs")
search = "duckdb analytics"

from doc in "docs",
  where: bm25(^schema, doc.id, ^search) > 0,
  order_by: [desc: bm25(^schema, doc.id, ^search)],
  limit: 10,
  select: %{
    id: doc.id,
    title: doc.title,
    score: bm25(^schema, doc.id, ^search)
  }
```

See the [full-text search guide](guides/full-text-search.md).

### Text and regex predicates

DuckDB text and RE2 regular-expression helpers compose with Ecto filters and aggregate `FILTER` clauses. Shared `contains/2` dispatches obvious string calls to DuckDB `contains` and spatial helper expressions to `ST_Contains`; ambiguous calls raise so `contains_text/2` and `st_contains/2` are available when you want to be explicit.

```elixir
use QuackDB.Ecto

from event in "events",
  where: contains(event.name, "duck") and regexp_matches(event.name, ~r/^duck/i),
  select: %{
    slug: regexp_replace(event.name, ~r/\s+/, "-", "g"),
    parts: string_split(event.tags, ",")
  }
```

DuckDB regexes use RE2, so `~r` literals are intended for the syntax subset shared with Elixir regexes.

### Pivoting and grouping extensions

DuckDB statement-level syntax such as `PIVOT`, `UNPIVOT`, `GROUPING SETS`, `ROLLUP`, and `CUBE` is best handled with small SQL builders rather than raw strings:

```elixir
MyApp.AnalyticsRepo.query!(QuackDB.SQL.pivot(:events,
  on: :kind,
  using: [sum: :n]
))

QuackDB.SQL.grouping_sets([[:category, :kind], [:category], []])
QuackDB.SQL.rollup([:category, :kind])
QuackDB.SQL.cube([:category, :kind])
```

### List predicates

DuckDB LIST/ARRAY helpers map directly to common list functions such as `list_contains`, `list_has_any`, `list_has_all`, `len`, `list_extract`, `list_sort`, `list_intersect`, `list_filter`, `list_transform`, `list_reduce`, and `unnest`. `use QuackDB.Ecto` imports non-conflicting list helpers by default; use `contains_list/2` and `intersect_list/2` to avoid ambiguity with text/spatial `contains/2` and Ecto set-operation `intersect/2`.

```elixir
use QuackDB.Ecto

from fragment in "fragments",
  where: contains_list(fragment.terms, ^term_id) and has_any(fragment.terms, ^optional_term_ids),
  select: %{
    id: fragment.id,
    term_count: list_length(fragment.terms),
    first_term: extract(fragment.terms, 1),
    matching_terms: intersect_list(fragment.terms, ^optional_term_ids),
    large_terms: list_filter(fragment.terms, fn term -> term > ^min_term_id end),
    doubled_terms: list_transform(fragment.terms, fn term -> term * 2 end),
    term_labels:
      list_transform(fragment.terms, fn term ->
        case_when do
          term >= 100 -> "large"
          true -> "small"
        end
      end),
    term_total: list_reduce(fragment.terms, fn total, term -> total + term end, 0),
    term: unnest(fragment.terms)
  }
```

MAP and STRUCT helpers follow the same pattern: natural names are available from focused imports, while `use QuackDB.Ecto` exposes explicit aliases for ambiguous helpers.

```elixir
use QuackDB.Ecto

from event in "events",
  where: contains_map(event.labels, ^"env") and contains_struct(event.metadata_tuple, ^"duck"),
  select: %{
    label_keys: map_keys(event.labels),
    env: map_extract_value(event.labels, ^"env"),
    name: struct_extract(event.metadata, ^"name")
  }
```

### Spatial queries

DuckDB Spatial works with Ecto queries and `%Geo.*{}` structs when the optional `:geo` package is installed.

```elixir
use QuackDB.Ecto

import QuackDB.Ecto.Spatial

alias QuackDB.Spatial

MyApp.AnalyticsRepo.query!(Spatial.load())

point = %Geo.Point{coordinates: {13.405, 52.52}, srid: nil}

from place in "places",
  where: intersects(place.geom, ^point) and distance(place.geom, ^point) < 1_000,
  select: %{
    id: place.id,
    name: place.name,
    wkt: as_text(place.geom)
  }
```

`GEOMETRY` values decode as WKB-compatible bytes for tested DuckDB Spatial values. `QuackDB.Geometry` can convert to/from `%Geo.*{}` structs when the optional `:geo` package is installed. See the [spatial guide](guides/spatial.md) and the [Spatial WMS example](https://github.com/elixir-vibe/quackdb/tree/master/examples/spatial_wms).

## Writes and dataframes

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

Explicit MAP columns accept ordinary Elixir maps while plain map inference stays STRUCT-shaped:

```elixir
QuackDB.insert_rows!(conn, "events", [[id: 1, labels: %{env: "prod", region: "eu"}]],
  columns: [id: :integer, labels: {:map, :varchar, :varchar}]
)
```

When Explorer is installed, dataframes can be appended directly:

```elixir
alias Explorer.DataFrame
alias QuackDB.Explorer, as: QuackExplorer

frame = DataFrame.new(id: [1, 2], name: ["duck", "goose"])
QuackExplorer.insert_dataframe!(conn, "events", frame)
```

Enumerable rows can be streamed into native append batches. The connection can be a QuackDB connection or a QuackDB-backed Ecto repo:

```elixir
File.stream!("events.ndjson")
|> Stream.map(&Jason.decode!/1)
|> QuackDB.insert_stream!(MyApp.AnalyticsRepo, "events", chunk_every: 10_000)
```

Any `Table.Reader`-compatible data can be appended through the same column append path:

```elixir
QuackDB.insert_table!(conn, "events", %{id: [1, 2], name: ["duck", "goose"]})
```

Append supports explicit types, batching, scalar DuckDB values, and nested `LIST`, `STRUCT`, `ARRAY`, and `MAP` values. Ecto `insert_all(..., insert_method: :append)` can use schema types for nullable batches, omitted/defaulted columns, and `RETURNING` through a temporary append table. See the [type support guide](guides/type-support.md), [getting started guide](guides/getting-started.md), and the [Explorer guide](guides/explorer.md).

## Results, Livebook, and telemetry

`QuackDB.Result` and `QuackDB.Columns` implement `Table.Reader`, so they can be consumed by Livebook and other Table-aware tooling. When Explorer is installed, query results can be turned into dataframes:

```elixir
result = QuackDB.query!(conn, "SELECT * FROM events")
Explorer.DataFrame.new(result)
```

QuackDB emits telemetry spans for query, append, and fetch operations:

- `[:quackdb, :query, :start | :stop]`
- `[:quackdb, :append, :start | :stop]`
- `[:quackdb, :fetch, :start | :stop]`

Metadata includes connection/session information, command details, append batch counts, and client query IDs. Params are not included unless you opt in with `telemetry_params: true`. See the [telemetry guide](guides/telemetry.md).

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

Use `QuackDB.Storage` to inspect how DuckDB stores and compresses tables:

```elixir
QuackDB.Storage.info!(MyApp.AnalyticsRepo, MyApp.Fragment)
QuackDB.Storage.compression!(MyApp.AnalyticsRepo, MyApp.Fragment)
QuackDB.Storage.database_size!(MyApp.AnalyticsRepo)
QuackDB.Storage.checkpoint!(MyApp.AnalyticsRepo)
```

`info!/2` wraps DuckDB's `pragma_storage_info` output as segment structs. `compression!/2` groups segment compression by table column, accepting schema modules, atoms, strings, and `{prefix, source}` tuples.

Use `QuackDB.Meta` for logical catalog metadata:

```elixir
QuackDB.Meta.tables!(MyApp.AnalyticsRepo)
QuackDB.Meta.tables!(MyApp.AnalyticsRepo, expanded: true)
QuackDB.Meta.table_info!(MyApp.AnalyticsRepo, MyApp.Fragment)
QuackDB.Meta.databases!(MyApp.AnalyticsRepo)
```

## Ecto coverage

QuackDB includes an optional Ecto SQL adapter for applications that want Ecto query composition, schema-based reads/writes, migrations, and raw SQL through `Repo.query/3`.

```elixir
defmodule MyApp.AnalyticsRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

The adapter currently covers:

- raw SQL via `Repo.query/3`;
- schema-backed full selects and `Repo.get!/2`;
- analytical reads with joins, filters, grouping, windows, CTEs, combinations, locks, fragments, and QuackDB helper macros;
- `Repo.insert/2`, `Repo.insert_all/3`, `RETURNING`, `ON CONFLICT DO NOTHING`, and common `DO UPDATE` upserts;
- explicit native append fast path via `insert_method: :append`, including schema-backed subset columns/defaults and `RETURNING`;
- `update_all`, `delete_all`, schema `update/delete`, and transaction usage;
- `Ecto.Adapters.SQL.explain/4`;
- basic migration DDL through Ecto migrator: create/drop/alter tables, columns, references, indexes, primary keys, check constraints, and renames.

DuckDB-specific SQL that Ecto cannot model cleanly should still use `Repo.query/3`. See the [Ecto coverage matrix](docs/ecto-analytical-coverage.md).

## Examples

The repository includes runnable scripts, a Livebook notebook, and a small WMS app:

- [`examples/ecto_analytics.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/ecto_analytics.exs) — Ecto analytical aggregates, text predicates, and DuckDB `SUMMARIZE` profiling.
- [`examples/source_sampling.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/source_sampling.exs) — JSON source scanning, `USING SAMPLE`, Ecto composition, and sampled source profiling.
- [`examples/dataframe_analytics.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/dataframe_analytics.exs) — derive DDL from an Ecto schema, append an Explorer dataframe, query with Ecto DSL, and return a dataframe.
- [`examples/full_text_search.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/full_text_search.exs) — materialize a source scan, build a DuckDB FTS index, and query BM25 search through direct helpers and Ecto.
- [`examples/spatial_wms/`](https://github.com/elixir-vibe/quackdb/tree/master/examples/spatial_wms) — an Ash + Ecto + Plug/Bandit app serving DuckDB Spatial rows through a WMS-like GeoJSON endpoint.
- [`examples/query_observability.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/query_observability.exs) — attach telemetry handlers and print query, append, and fetch timings.
- [`examples/append_benchmark.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/append_benchmark.exs) — compares SQL inserts, native row/column append, Explorer append, and Ecto insert paths.
- [`examples/livebook_analytics.livemd`](https://github.com/elixir-vibe/quackdb/blob/master/examples/livebook_analytics.livemd) — interactive analytics with DuckDB SQL, Explorer, Table.Reader, VegaLite, and telemetry.

Run scripts from outside the Mix project so `Mix.install/2` can load the local package:

```sh
cd /tmp
elixir /path/to/quackdb/examples/dataframe_analytics.exs
```

## Current boundaries

QuackDB is intentionally focused on DuckDB analytics over Quack:

- the Quack wire protocol is experimental and may change;
- unsupported vector/logical types raise explicit protocol errors;
- Ecto coverage focuses on analytical workflows and common write/setup paths, not every adapter edge case;
- QuackDB does not stage/upload local files to a remote server;
- Arrow IPC / zero-copy columnar handoff is research for now;
- managed DuckDB binary downloads currently cover Linux/macOS targets, not Windows.

## Documentation

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

## Development

```sh
mix deps.get
mix ci
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for local checks, example smoke tests, package audit steps, and release dry-run notes.

Integration tests run automatically when a local DuckDB executable is available. Set `QUACKDB_SKIP_INTEGRATION=1` to skip them, `QUACKDB_TEST_DUCKDB=managed` to force the managed binary path, or `QUACKDB_TEST_URI` / `QUACKDB_TEST_TOKEN` to reuse an external Quack server.

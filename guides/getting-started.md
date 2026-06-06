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
    {:quackdb, "~> 0.3.0"}
  ]
end
```

Optional integrations are compiled only when their packages are available. Add Explorer when you want dataframe handoff helpers:

```elixir
def deps do
  [
    {:quackdb, "~> 0.3.0"},
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
children =
  QuackDB.Server.child_specs(
    server: [name: MyApp.DuckDB, duckdb: :managed, endpoint: "quack:localhost:9494"],
    client: [name: MyApp.QuackDB, pool_size: System.schedulers_online()]
  )
```

`child_specs/1` generates one shared random token and injects the matching URI/token into both child specs. Pass `:token` on either side when you want to provide it yourself.

`duckdb: :managed` downloads and caches DuckDB's official CLI binary when the local server starts. Managed downloads are checksum-verified for `QuackDB.Binary.default_version/0`; other DuckDB versions require passing an explicit `:sha256`. For explicit setup, run:

```sh
mix quackdb.install
mix quackdb.install --print-path
```

Use `QUACKDB_BINARY_PATH` or pass `duckdb: "/path/to/duckdb"` when you want QuackDB to use a system or custom executable instead. See the [managed DuckDB guide](managed-duckdb.md) for cache, checksum, and target-prefetch options.

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

DuckDB can scan files, object stores, and lakehouse table formats directly. `QuackDB.Source` builds safe table-function fragments that can be used from Ecto queries or direct SQL:

```elixir
use QuackDB.Ecto

alias QuackDB.Source

source = Source.csv("events.csv", header: true)

MyApp.AnalyticsRepo.all(
  from event in source,
    where: event.id > 1,
    select: %{id: event.id, name: event.name}
)
```

See [`guides/sources.md`](sources.md) for HTTP(S), S3/R2/GCS, Azure/ADLS, Hugging Face, Delta, Iceberg, extensions, and DuckDB secrets.

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

Ecto queries can be passed directly when you already have schemas or source helpers:

```elixir
import Ecto.Query

alias QuackDB.Explorer, as: QuackExplorer
alias QuackDB.Source

source = Source.csv("events.csv", header: true)

query =
  from event in source,
    where: event.id > ^1,
    select: %{id: event.id, name: event.name}

{:ok, df} = QuackExplorer.dataframe(conn, query)
```

The Explorer integration materializes query results in Elixir before constructing a dataframe. It is useful for interactive analysis and downstream Explorer pipelines, but it is not a zero-copy Arrow IPC path yet.

Explorer dataframes can also be appended through Quack's native column-oriented append path:

```elixir
alias QuackDB.Explorer, as: QuackExplorer

QuackExplorer.insert_dataframe!(conn, "events_copy", df, batch_size: 10_000)
```

You can also convert existing results:

```elixir
alias QuackDB.Explorer, as: QuackExplorer

{:ok, result} = QuackDB.query(conn, "SELECT 1 AS id, 'duck' AS name")
{:ok, df} = QuackExplorer.from_result(result)
```

## Work with command results

DuckDB returns affected counts as a `Count` result column for DML statements. QuackDB normalizes those into `num_rows`:

```elixir
alias QuackDB.{DDL, DML}

{:ok, _} = QuackDB.query(conn, DDL.create_table("events", [id: :integer], temporary: true))
{:ok, result} = QuackDB.query(conn, DML.insert_into("events", [[id: 1], [id: 2]]))

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
alias QuackDB.DDL

QuackDB.query!(conn, DDL.create_table("events", [id: :integer, name: :varchar, active: :boolean], temporary: true))

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

Native append columns can be declared with scalar `QuackDB.Type` specs and nested specs such as `{:list, :varchar}`, `{:struct, [source: :varchar, count: :integer]}`, `{:array, :integer, 3}`, and `{:map, :varchar, :varchar}`. Explicit MAP columns accept ordinary Elixir maps:

```elixir
QuackDB.insert_rows!(conn, "events", [[id: 1, labels: %{env: "prod", region: "eu"}]],
  columns: [id: :integer, labels: {:map, :varchar, :varchar}]
)
```

Plain Elixir maps without an explicit MAP column spec infer as DuckDB `STRUCT` values. Temporal append values are normalized through Elixir's Calendar-aware `Date`, `Time`, `NaiveDateTime`, and `DateTime` conversion APIs before encoding.

## Full-text search helpers

DuckDB's `fts` extension can index text columns and expose BM25 ranking.

```elixir
alias QuackDB.FTS

MyApp.AnalyticsRepo.query!(FTS.install())
MyApp.AnalyticsRepo.query!(FTS.load())

MyApp.AnalyticsRepo.query!(
  FTS.create_index("documents", :id, [:title, :body], overwrite: true)
)

from doc in "documents",
  where: match_bm25("fts_main_documents", doc.id, ^"duckdb analytics") > 0,
  order_by: [desc: match_bm25("fts_main_documents", doc.id, ^"duckdb analytics")],
  select: %{id: doc.id, title: doc.title}
```

See the [full-text search guide](full-text-search.md) for direct SQL and Ecto usage.

## Spatial helpers

DuckDB's spatial extension can be loaded with SQL helpers. Use Ecto spatial helpers when you want to keep spatial expressions inside Ecto queries:

```elixir
use QuackDB.Ecto

alias QuackDB.Spatial

QuackDB.query!(conn, Spatial.load())

point = %Geo.Point{coordinates: {1.0, 2.0}, srid: nil}

from(place in "places",
  where: intersects(place.geom, ^point),
  select: as_text(place.geom)
)
```

DuckDB `GEOMETRY` values decode as WKB-compatible bytes. Add optional `{:geo, "~> 4.1"}` when you want to convert those bytes to `Geo` structs with `QuackDB.Geometry.decode_wkb!/1`, or pass `%Geo.*{}` structs as Ecto parameters.

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
alias QuackDB.{DDL, DML}

DBConnection.transaction(conn, fn tx ->
  QuackDB.query!(tx, DDL.create_table("tx_events", [id: :integer], temporary: true))
  QuackDB.query!(tx, DML.insert_into("tx_events", id: 1))
end)
```

## Ecto raw SQL

QuackDB includes an initial Ecto SQL adapter for raw SQL queries. The Ecto adapter is compiled when `ecto_sql` is available, so add Ecto SQL if your app does not already depend on it:

```elixir
def deps do
  [
    {:quackdb, "~> 0.3.0"},
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

Generated DDL and setup-oriented DML can participate in Ecto transactions:

```elixir
{:ok, :committed} =
  MyApp.AnalyticsRepo.transaction(fn ->
    MyApp.AnalyticsRepo.query!(
      QuackDB.DDL.create_table("events", [id: :integer], temporary: true)
    )

    MyApp.AnalyticsRepo.query!(QuackDB.DML.insert_into("events", [[id: 1], [id: 2]]))
    :committed
  end)
```

Use `Repo.rollback/1` to abort transaction work:

```elixir
{:error, :rolled_back} =
  MyApp.AnalyticsRepo.transaction(fn ->
    MyApp.AnalyticsRepo.query!(QuackDB.DML.insert_into("events", id: 3))
    MyApp.AnalyticsRepo.rollback(:rolled_back)
  end)
```

Read-only Ecto queries against table names are also supported, including CTEs, window functions, joins, grouping, having, distinct, aggregate `FILTER`, arithmetic expressions, `in/2`, predicates, ordering, limits, aggregates, fragments, and DuckDB analytical helpers:

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: event.id > ^min_id and like(event.name, "d%"),
    group_by: event.category,
    select: %{
      category: event.category,
      median_score: median(event.score),
      p95_score: quantile_cont(event.score, 0.95),
      scores: list(event.score),
      high_score_events: filter(count(event.id), event.score > 100)
    }
)
```

Build date spines and timestamp buckets with Elixir-native `Date.Range` and `Duration` values:

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
  from day in series(Date.range(~D[2024-01-01], ~D[2024-01-31])),
    left_join: event in "events",
    on: event.occurred_on == day.value,
    group_by: day.value,
    order_by: day.value,
    select: %{day: day.value, events: count(event.id)}
)

interval = Duration.new!(hour: 1)
origin = ~N[2024-01-01 00:00:00]

MyApp.AnalyticsRepo.all(
  from event in "events",
    group_by: selected_as(:bucket),
    select: %{
      bucket: selected_as(time_bucket(^interval, event.occurred_at, origin: ^origin), :bucket),
      events: count()
    }
)
```

Text and regex helpers keep DuckDB string predicates in the query DSL. DuckDB regexes use RE2; `~r` literals are convenient for the syntax shared with Elixir regexes, and `contains/2` dispatches obvious text calls to DuckDB `contains` while spatial helper calls go to `ST_Contains`. Ambiguous calls raise; use `contains_text/2` or `st_contains/2` when intent is not obvious:

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: contains(event.name, "duck") and regexp_matches(event.name, ~r/^duck/i),
    select: %{
      slug: regexp_replace(event.name, ~r/\s+/, "-", "g"),
      tags: string_split(event.tags, ",")
    }
)
```

LIST columns can use helpers for containment, intersection, all-required matching, extraction, sorting, slicing, lambda filtering/transforms/reductions, and unnesting. `use QuackDB.Ecto` imports list helpers by default; `contains_list/2` and `intersect_list/2` avoid ambiguity with shared predicate/set-operation names:

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
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
)
```

MAP and STRUCT columns can use focused helpers for key/value inspection and field extraction. With `use QuackDB.Ecto`, use explicit aliases for helpers that would otherwise conflict with list/text/spatial helpers.

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: contains_map(event.labels, ^"env") and contains_struct(event.metadata_tuple, ^"duck"),
    select: %{
      label_keys: map_keys(event.labels),
      env: map_extract_value(event.labels, ^"env"),
      name: struct_extract(event.metadata, ^"name")
    }
)
```

JSON columns can use Ecto access syntax for string extraction, `type/2` for numeric/boolean casts, or explicit DuckDB JSON helpers:

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
  from event in "events",
    where: event.payload["user"]["name"] == "duck" and type(event.payload["score"], :integer) > 10,
    select: %{
      name: event.payload["user"]["name"],
      active: type(event.payload["active"], :boolean),
      score: json_extract(event.payload, [:scores, 0]),
      has_name: json_exists(event.payload, [:user, :name])
    }
)
```

DuckDB's `QUALIFY` clause is not part of Ecto's query AST. Use an Ecto subquery when filtering window function results:

```elixir
ranked =
  from event in "events",
    windows: [by_category: [partition_by: event.category, order_by: [desc: event.score]]],
    select: %{
      id: event.id,
      category: event.category,
      score: event.score,
      rank: over(row_number(), :by_category)
    }

MyApp.AnalyticsRepo.all(
  from event in subquery(ranked),
    where: event.rank <= 3,
    order_by: [event.category, event.rank]
)
```

Use `case_when` for multi-branch DuckDB `CASE WHEN` expressions inside queries:

```elixir
use QuackDB.Ecto

MyApp.AnalyticsRepo.all(
  from event in "events",
    group_by: [date_part(:hour, event.occurred_at), selected_as(:tier)],
    select: %{
      hour: date_part(:hour, event.occurred_at),
      tier:
        selected_as(
          case_when do
            event.score >= 90 -> "high"
            event.score >= 50 and event.score <= 89 -> "medium"
            true -> "normal"
          end,
          :tier
        ),
      events: count(),
      distinct_events: count(event.id, :distinct),
      high_events: filter(count(event.id), event.score >= 90),
      average_score: coalesce(avg(event.score), 0),
      precise_score_sum: fsum(event.score),
      mode_score: mode(event.score),
      weighted_score: weighted_avg(event.score, event.weight),
      score_stddev: stddev(event.score),
      score_variance: variance(event.score),
      score_entropy: entropy(event.score),
      score_histogram: histogram(event.score),
      ordered_scores: list(event.score, order_by: [desc_nulls_last: event.score])
    }
)
```

Profile an Ecto queryable with DuckDB `SUMMARIZE` when you need a quick statistical overview:

```elixir
query =
  from event in "events",
    where: event.score > 0,
    select: %{category: event.category, score: event.score}

QuackDB.Ecto.Analytics.summarize!(MyApp.AnalyticsRepo, query)
```

For table/source names or raw SQL outside Ecto, use the direct SQL helper:

```elixir
MyApp.AnalyticsRepo.query!(QuackDB.Analytics.summarize("events"))
MyApp.AnalyticsRepo.query!(QuackDB.Analytics.summarize({:query, "SELECT score FROM events"}))
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

Use `insert_method: :append` to opt into Quack's native append protocol for bulk `insert_all` workloads. This path is explicit: ordinary `insert_all` keeps using Ecto SQL generation unless you pass the option.

```elixir
MyApp.AnalyticsRepo.insert_all(
  Event,
  [[name: "duck"], [name: "goose"]],
  insert_method: :append,
  chunk_every: 10_000
)
```

For schema-backed inserts, QuackDB derives append types from the Ecto schema. That means nullable columns can be all `nil` in a batch without passing manual `:columns`, and omitted schema fields can be filled by DuckDB defaults or generated values. `RETURNING` is supported through a temporary append table followed by `INSERT ... RETURNING`:

```elixir
MyApp.AnalyticsRepo.insert_all(
  Event,
  [[name: "duck"], [name: "goose"]],
  insert_method: :append,
  returning: [:id]
)
```

The append insert path does not support query inserts, placeholders, or upserts/conflict targets. For streaming rows outside Ecto, use `QuackDB.insert_stream!/4`; it can take either a QuackDB connection or a QuackDB-backed Ecto repo.

For temporary analytical setup, `QuackDB.DDL.create_table/3` builds quoted DuckDB `CREATE TABLE` and `CREATE TABLE AS` statements:

```elixir
MyApp.AnalyticsRepo.query!(
  QuackDB.DDL.create_table("events",
    [payload: :json, occurred_at: :timestamp],
    temporary: true
  )
)

source = QuackDB.Source.parquet("s3://bucket/events/*.parquet")

query =
  from event in source,
    select: %{id: event.id, name: event.name}

MyApp.AnalyticsRepo.query!(
  QuackDB.DDL.create_table("events_from_parquet", as: query, temporary: true)
)
```

`DDL.create_table/2` rejects parameterized Ecto queries in `:as` because DDL helpers return SQL iodata, not `{sql, params}` tuples.

Ecto support covers analytical reads and common write/setup flows. `Repo.query/3`, schema-backed reads, combinations, inserts/upserts, schema update/delete callbacks, `update_all` / `delete_all` mutations, `EXPLAIN`, transactions, and basic migrator-backed DDL work; advanced migration features and DuckDB-specific SQL should still use `Repo.query/3`.

### Basic Ecto migrations

QuackDB implements the Ecto migration DDL callbacks needed for common analytical setup migrations:

```elixir
defmodule MyApp.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:name, :string, null: false)
      add(:score, :integer, default: 0)
    end

    create(index(:events, [:name]))
    create(constraint(:events, :positive_score, check: "score >= 0"))
  end
end
```

Supported DDL includes create/drop/alter table, add/modify/drop columns, references, ordinary and unique indexes, primary keys, composite primary keys, check constraints, and table/column renames. DuckDB-incompatible options such as concurrent indexes, covering indexes, exclude constraints, constraint comments, and `NOT VALID` constraints raise explicit QuackDB errors.

## Current limitations

- Server-side bind parameters are not exposed by this Quack client path yet. QuackDB formats supported parameter values as DuckDB SQL literals client-side.
- Native appends support row and column batches but not Arrow IPC or automatic local-file/data staging yet.
- Ecto coverage focuses on analytical reads and common write/setup workflows, not every relational adapter feature.
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

`QuackDB.Server` starts the external `duckdb` executable and serves the Quack protocol. It is a convenience process supervisor, not an embedded DuckDB driver and not required for remote DuckDB servers. Use `duckdb: :managed` for local development convenience, or omit it to use `duckdb` from `PATH`.

The local server defaults to `settings: [threads: System.schedulers_online()]` and `global_settings: [quack_fetch_batch_chunks: 4]`. Use a smaller client `pool_size` such as `1..4` for heavy analytical scans, because DuckDB parallelizes each query internally. Use `System.schedulers_online()` for many small concurrent queries.

## Running QuackDB's integration tests

With a server running locally:

```sh
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

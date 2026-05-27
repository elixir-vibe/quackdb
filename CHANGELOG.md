# Changelog

## Unreleased

### Added

- Added `Duration.t()` SQL parameter support.
- Added Ecto `time_bucket/2,3` compatibility for pinned Elixir durations, origins, and offsets.
- Added typed Ecto `series/1,3` helpers for DuckDB `generate_series` date/timestamp sources.
- Added JSON SQL parameters/path helpers plus Ecto access syntax and `type/2` casts.
- Added Ecto regular-expression helpers for DuckDB `regexp_*` functions with compatible `~r` modifier translation.
- Added `case_when` syntax for DuckDB `CASE WHEN` and atom date parts.
- Added ordered `list/2` and `string_agg/3` with NULL ordering.
- Added Ecto `count(..., :distinct)` and `coalesce/2` SQL generation.
- Added `arg_max/3`, `arg_min/3`, approximate aggregate, boolean aggregate, Bitwise-style bit aggregate, statistical, precise floating-point aggregate, weighted aggregate, product, and histogram helpers.
- Added value window functions with fragment-backed frames.
- Added direct and Ecto queryable `SUMMARIZE` profiling helpers.
- Added DuckDB function snapshot task with normalized QuackDB type specs for overload auditing.
- Added protocol coverage and quack-ts parity docs plus expanded type/null/append conformance coverage.
- Added source sampling and metadata examples, enumerable stream append, and Table.Reader input append.

## 0.3.0 - 2026-05-26

### Added

#### Local DuckDB and transport

- Replaced Req-based HTTP calls with a stateful Mint transport owned by each DBConnection process, with explicit connect/receive/shutdown timeouts, closed-connection reopening, and safer timeout cleanup.
- Added process-local Quack client query IDs for query, append, and telemetry correlation.
- Added local server performance defaults and `QuackDB.Server` `:settings` / `:global_settings` boot options.
- Added explicit DuckDB binary management through `QuackDB.Binary`, `mix quackdb.install`, and `QuackDB.Server` `duckdb: :managed`, with built-in checksums for the pinned DuckDB CLI downloads.
- Added managed DuckDB binary guide and install-task target prefetching.
- Documented managed DuckDB Windows limitations and linked the managed binary guide from getting started docs.

#### Native writes, Explorer, and columnar results

- Added `QuackDB.insert_columns/4` / `insert_columns!/4` for column-oriented native append batches.
- Added `QuackDB.Explorer.insert_dataframe/4` / `insert_dataframe!/4` for appending Explorer dataframes through native column append.
- Added optional `Table.Reader` implementations for `QuackDB.Result` and `QuackDB.Columns`.

#### DuckDB helpers, sources, and setup SQL

- Added schema-driven `QuackDB.DDL.create_table/2`, `CREATE TABLE AS` query support with explicit parameterized-query rejection, and `QuackDB.DML.insert_into/2` setup helpers.
- Added `QuackDB.Extension` helpers for DuckDB `INSTALL` and `LOAD` statements.
- Added `QuackDB.Secret` helpers for DuckDB HTTP, object-storage, Azure, and Hugging Face secrets.
- Added a focused sources guide for DuckDB file/object-store/lakehouse sources, extensions, and secrets.
- Clarified that QuackDB does not automatically upload local source files.

#### Expanded Ecto adapter

- Added `use QuackDB.Ecto` to import Ecto query, analytical, spatial, and FTS helpers together.
- Added Ecto combinations, lock SQL, schema full selects, `Repo.get!/2`, `Repo.explain/3`, and additional analytical query expressions including `selected_as`, `map`, `type`, and identifier fragments.
- Added Ecto upsert SQL generation, schema update/delete callbacks, `update_all` / `delete_all`, joined mutations, and rowid-filtered ordered/limited mutations where DuckDB SQL allows it.
- Added basic migration DDL generation with real-server coverage for create/drop/alter tables, table/column renames, references, indexes, primary keys, composite primary keys, check constraints, and `Ecto.Migrator` execution.
- Expanded Ecto parameter and schema coverage for `:binary_id`, `:binary`, UUID/blob raw params, intervals, temporal values, decimals, arrays, and Geo spatial params.

#### Protocol and DuckDB type fidelity

- Added conversion helpers and compact inspect output for DuckDB-specific scalar structs.
- Added decode-side checks for quack-ts protocol conformance fixtures.
- Added quack-ts decode fixtures for nanosecond temporal, interval, spatial geometry, null-heavy nested chunks, and `BIGNUM` values.
- Added malformed protocol coverage for truncated `BIGNUM` values and mismatched data chunk type/vector counts.
- Added an optional internal `:fsst` bridge for future Quack FSST payload decoding once DuckDB exposes compressed FSST vectors over Quack.

#### Spatial, FTS, and observability

- Added `QuackDB.SQL.install/1`, `QuackDB.Spatial`, and `QuackDB.Ecto.Spatial` helpers for DuckDB spatial extension statements and `ST_*` expressions.
- Added optional `QuackDB.Geometry` WKB conversion helpers and `%Geo.*{}` SQL/Ecto parameter support when the `:geo` package is available.
- Added `QuackDB.FTS` and `QuackDB.Ecto.FTS` helpers for DuckDB FTS indexes, BM25 search ranking, stemming, and Ecto search expressions.
- Added `:telemetry` events for query, append, and fetch operations, including custom prefixes, metadata options, optional params, and append batch counts.

#### Docs and examples

- Added examples for telemetry observation, Explorer dataframe roundtrips, append benchmarks, full-text search, Livebook analytics, and a WMS-like spatial GeoJSON app.
- Added contributor documentation for CI, docs, integration, examples, optional dependency smoke checks, and Hex package-content audits.
- Added Arrow/columnar handoff research notes and protocol fixture docs for tricky scalar/spatial types.

### Fixed

- Expanded real Ecto insert coverage for `on_conflict: :nothing`, single-row insert upserts, insert-from-query SQL paths, renamed `:binary_id` sources, and binary payloads containing NUL bytes.
- Fixed Mint transport call timeout handling for `timeout: :infinity`, which Ecto migrator uses for migration DDL.
- Closed Mint transport connections after receive timeouts to avoid reusing sockets with abandoned in-flight responses.
- Updated user docs to reflect current Ecto migration, write, schema-read, package, and protocol coverage.

## 0.2.0 - 2026-05-25

### Added

- Added `QuackDB.Server`, an optional MuonTrap-backed supervisor for local DuckDB Quack server processes.
- Added `QuackDB.DDL` and `QuackDB.Type` helpers for quoted DuckDB DDL and SQL type rendering.
- Added `QuackDB.Ecto.Analytics` helpers for DuckDB analytical expressions in Ecto queries, including median, quantiles, list aggregation, JSON extraction, date truncation, and time buckets.
- Added generic `QuackDB.SQL.load/1` and `QuackDB.SQL.call/3` statement builders.
- Added Quack append-protocol encoding and `QuackDB.insert_rows/4` / `insert_rows!/4` for appending keyword rows or row maps as DuckDB `DataChunk`s, including `:batch_size`, nested `LIST` / `STRUCT` / `ARRAY` / `MAP` values, Calendar-aware temporal encoding, `BIGNUM`, nanosecond temporal values, `TIME WITH TIME ZONE`, and interval structs.
- Added Ecto `insert/2` and `insert_all/3` support for straightforward row inserts, `insert_all` `RETURNING` coverage, and an explicit `insert_method: :append` native append fast path.
- Expanded analytical integration coverage for JSON sources, time-series functions, source analytics, `QUALIFY`, `PIVOT`, `UNPIVOT`, grouping sets, sampling, and supervised local servers.

- Added `QuackDB.Interval`, `QuackDB.NanosecondTime`, `QuackDB.NanosecondTimestamp`, and `QuackDB.TimeWithTimeZone` value structs for DuckDB-specific scalar fidelity.

### Changed

- Split Ecto query SQL generation into `Ecto.Adapters.QuackDB.Query`.
- Reworked integration test setup around reusable QuackDB test helpers that dogfood public DDL/type/source utilities.
- Replaced production regex-based source/command parsing with explicit binary/string scanners.


## 0.1.1 - 2026-05-23

### Added

- Added `QuackDB.Source` helpers for DuckDB Parquet, CSV, JSON, XLSX, Delta, and Iceberg table-function fragments, including use as Ecto query sources.
- Added optional `QuackDB.Explorer` helpers for converting QuackDB results and Ecto queries into `Explorer.DataFrame` values when Explorer is available.
- Added `QuackDB.Columns`, `QuackDB.columnar/4`, `QuackDB.columnar!/4`, `QuackDB.columnar_batches/4`, `QuackDB.columns/4`, `QuackDB.columns!/4`, `QuackDB.column_batches/4`, and result conversion helpers for column-oriented analytical results.
- Expanded read-only Ecto query generation with CTEs, window functions, joins, grouping, having, distinct, aggregate `FILTER`, arithmetic expressions, `in/2`, common aggregates, `like/2`, nil checks, and simple fragments.
- Added a DuckDB type support guide and real-server integration coverage for scalar and nested type families.
- Added UUID and ENUM result decoding.
- Added conservative client-side SQL parameter formatting for raw queries and Ecto pinned parameters.
- Added row-level and map-level streaming helpers for large result sets.
- Hardened streaming helper behavior around early halt, later fetch errors, and duplicate map column names.
- Added property tests for protocol reader/writer primitive roundtrips and malformed input handling.
- Changed `BIT` result decoding from raw DuckDB payload bytes to readable bit strings.
- Added compact inspect implementations for streams, cursors, and data chunks.
- Added `QuackDB.ping/2` and documented supervision/connection options.

## 0.1.0 - 2026-05-23

### Added

- Initial remote DuckDB Quack protocol client backed by `DBConnection`.
- Binary Quack protocol codec with message, logical type, data chunk, vector, and scalar decoding support.
- HTTP transport for Quack endpoints.
- Query execution, prepare/execute, fetch continuation, streaming, and transaction support.
- Decoding for common scalar DuckDB types and nested result values including `LIST`, `STRUCT`, `ARRAY`, and `MAP`.
- Command result normalization for DuckDB `Count` outputs into affected-row `num_rows`.
- Compact `Inspect` implementations for easier IEx debugging.
- Initial Ecto SQL adapter support for raw `Repo.query/3`, transactions, and simple read-only `Repo.all/2` table queries.
- Gated real DuckDB Quack integration tests.

### Notes

- QuackDB itself is experimental: package APIs, result shapes, Ecto behavior, and supported type coverage may change before the project stabilizes.
- QuackDB follows DuckDB's experimental Quack protocol behavior.
- Ecto support is intentionally limited; set combinations, locks, migrations, updates, deletes, and upserts are not supported yet.

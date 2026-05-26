# Changelog

## Unreleased

### Added

- Added `QuackDB.insert_columns/4` / `insert_columns!/4` for column-oriented native append batches.
- Added `QuackDB.Explorer.insert_dataframe/4` / `insert_dataframe!/4` for appending Explorer dataframes through native column append.
- Added conversion helpers and compact inspect output for DuckDB-specific scalar structs.
- Added `QuackDB.SQL.install/1`, `QuackDB.Spatial`, and `QuackDB.Ecto.Spatial` helpers for DuckDB spatial extension statements and `ST_*` expressions.
- Added optional `QuackDB.Geometry` WKB conversion helpers and `%Geo.*{}` SQL/Ecto parameter support when the `:geo` package is available.
- Added `:telemetry` events for query, append, and fetch operations, including custom prefixes, metadata options, optional params, and append batch counts.
- Added optional `Table.Reader` implementations for `QuackDB.Result` and `QuackDB.Columns`.
- Added schema-driven `QuackDB.DDL.create_table/2` and `QuackDB.DML.insert_into/2` setup helpers.
- Added `QuackDB.Secret` helpers for DuckDB HTTP, object-storage, Azure, and Hugging Face secrets.
- Added `use QuackDB.Ecto` to import Ecto query, analytical, and spatial helpers together.
- Added a focused sources guide for DuckDB file/object-store/lakehouse sources, extensions, and secrets.
- Added examples for telemetry observation, Explorer dataframe roundtrips, append benchmarks, Livebook analytics, and a WMS-like spatial GeoJSON app.

### Fixed

- Expanded real Ecto insert coverage for `on_conflict: :nothing` and insert-from-query SQL paths.

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

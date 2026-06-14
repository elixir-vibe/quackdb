# Changelog

## Unreleased

## 0.5.6 - 2026-06-14

### Changed

- Optimized Ecto native append insert paths by keeping temporary append staging column-oriented when possible.
- Avoided duplicate column append encoding when computing row counts for batched native appends.

## 0.5.5 - 2026-06-13

### Fixed

- Added Ecto native append support for `Repo.insert_all/3` with `insert_method: :append`, `on_conflict: :nothing`, and `conflict_target`, including optional `returning`.

## 0.5.4 - 2026-06-10

### Added

- Added `QuackDB.DML.delete_from/2` for parameterized `DELETE ... WHERE ...` statements.
- Added support for additional Ecto query shapes, including `values` sources and merged map selects.
- Added Dialyxir to `mix ci` to catch public spec/type drift.

### Changed

- Switched signed LEB128 protocol encoding to `varint` now that upstream SLEB128 support is available.

### Fixed

- Fixed `QuackDB.FTS` types to include the documented `:schema` match option.
- Fixed Ecto fragment sources so table-valued functions such as `read_csv(...)` are not forced into a single `value` column alias.

## 0.5.3 - 2026-06-08

### Added

- Added `QuackDB.Sequence.next_values/4` for preallocating DuckDB sequence IDs before native append, `QuackDB.Sequence.for_column/4` for catalog-backed column sequence lookup, and `QuackDB.Ecto.column_sequence_name/2` for QuackDB's serial-column sequence naming convention.
- Added `QuackDB.Meta.primary_keys/3` and `column_defaults/3` helpers for table/column append planning.
- Added `append_shape: :columns | :rows` for explicit direct Ecto native append shape selection.

### Changed

- Reuse shape-specific Ecto append temporary tables to avoid repeated create/drop churn in `RETURNING` insert paths.

### Fixed

- Fixed quadratic list/map native append encoding for large batches with nested LIST/MAP values.

## 0.5.2 - 2026-06-08

### Added

- Added `QuackDB.Storage` observability helpers for DuckDB table storage segments, compression summaries, database size, and checkpointing.
- Added `QuackDB.Meta` catalog helpers for listing tables, attached databases, and logical table columns.
- Added `QuackDB.Server` `recovery_mode: :no_wal_writes` support for rebuildable local DuckDB databases.
- Added append telemetry phase metrics for encode, transport, decode, request/response bytes, append duration, and rows/sec.

### Changed

- Optimized row-oriented native append encoding for wide ordered keyword rows by transposing rows to columns in one pass.
- Switched unsigned LEB128 protocol encoding to `varint`.
- Optimized native append vector encoding by reducing redundant count and validity passes.
- Optimized Ecto append inserts by using column-oriented append for direct inserts and an ordered-row fast path for temporary append staging.
- Added ExDNA zero-duplication and Reach smell checks to `mix ci`.

## 0.5.1 - 2026-06-06

### Added

- Added `:or_replace` support to `QuackDB.DDL.create_table/2,3` and support for creating a differently named table from an Ecto schema via `QuackDB.DDL.create_table(name, schema, opts)`.
- Added `QuackDB.Profile` for DuckDB `EXPLAIN (ANALYZE, FORMAT json)` query profiles with structured operator helpers, and added `:format` support to `QuackDB.SQL.explain/2`.
- Added tests and documentation for Ecto insert-from-query staging/dedupe with `returning`.

### Changed

- Removed public `QuackDB.DDL.create_table_as/3`; use `QuackDB.DDL.create_table/2` or `/3` with the `:as` option instead.

### Fixed

- Fixed schema-backed append type inference for parameterized Ecto types such as `Ecto.Enum`.
- Fixed explicit `columns: [...]` preservation in schema-backed append inserts.
- Fixed Ecto `:map` append values by JSON-encoding maps for DuckDB `VARCHAR` append columns.
- Fixed full schema-backed native append value ordering to follow schema field-source order.

## 0.5.0 - 2026-06-06

### Added

- Added schema-backed Ecto append support for subset columns/defaulted values and `RETURNING` through a temporary append table plus Ecto insert-from-query SQL generation.
- Added support for using a QuackDB-backed Ecto repo directly with public `QuackDB` query and native append helpers.
- Added Ecto `exists/1` SQL generation and documented advanced join patterns for semi, anti, ASOF-style lateral, and positional joins.
- Added DuckDB star/columns SQL expression helpers and Ecto macros for `* EXCLUDE`, `* REPLACE`, `* RENAME`, pattern stars, `COLUMNS(...)`, and `*COLUMNS(...)`, including pinned dynamic `COLUMNS(?)` selectors.
- Added direct SQL and Ecto helpers for common DuckDB LIST operations including length, extraction, slicing, sorting, distinct/unique counts, position, intersection, and concatenation.
- Added direct SQL and Ecto helpers for common DuckDB MAP and STRUCT operations with focused natural names plus explicit aliases for broad `use QuackDB.Ecto` imports.
- Added raw SQL builders for DuckDB `PIVOT`, `UNPIVOT`, `GROUPING SETS`, `ROLLUP`, and `CUBE` syntax.
- Added Ecto LIST lambda helpers for DuckDB `list_filter`, `list_transform`, and `list_reduce` using constrained Elixir `fn` syntax, including `case_when` support, with clear macro-time errors.

### Changed

- Integration tests now auto-start a shared local Quack server when DuckDB is available, while still honoring explicit `QUACKDB_TEST_URI`/`QUACKDB_TEST_TOKEN` configuration.
- Improved `QuackDB.Server` startup readiness by detecting the `quack_serve` result row from DuckDB stdout, with HTTP polling retained as a fallback.
- Consolidated Ecto type-to-DuckDB type mapping for migration DDL, schema DDL helpers, and native append inference.

## 0.4.2 - 2026-05-31

### Added

- Added `QuackDB.SQL.explain/2` for building `EXPLAIN` and `EXPLAIN ANALYZE` statements.
- Added a development stress benchmark for local read, stream, columnar, and append scenarios.

### Changed

- Improved row and nested-list materialization performance for large result sets.
- Streamed `QuackDB.columnar_batches/4` through a columnar cursor path instead of materializing rows first.
- Updated large-result documentation to recommend row streaming or columnar batches for analytical results.

### Fixed

- Fixed nullable fixed-width vector decoding when DuckDB stores non-decodable bytes in invalid/null slots.

## 0.4.1 - 2026-05-31

### Added

- Added direct SQL and Ecto LIST helpers for `list_contains`, `list_has_any`, `list_has_all`, and `unnest`.
- Added Ecto SQL generation support for nested map/tuple select expressions and `IN (subquery(...))` predicates.

### Fixed

- Fixed Ecto nil insert values so `nil` is sent as a parameterized `NULL` instead of emitting `DEFAULT`.
- Fixed Ecto tagged source-field parameters in query predicates.
- Fixed Ecto lateral joins with `parent_as/1` by threading explicit source context through query rendering.
- Fixed DBConnection query caching and telemetry to preserve the original parameterized SQL while sending formatted SQL to DuckDB.
- Fixed Ecto map loading/dumping for JSON-backed map fields.

## 0.4.0 - 2026-05-29

### Added

- Added `Duration.t()` SQL parameter support.
- Added Ecto `time_bucket/2,3` compatibility for pinned Elixir durations, origins, and offsets.
- Added typed Ecto `series/1,3` helpers for DuckDB `generate_series` date/timestamp sources.
- Added JSON SQL parameters/path helpers plus Ecto access syntax and `type/2` casts.
- Added Ecto regular-expression helpers for DuckDB `regexp_*` functions with compatible `~r` modifier translation.
- Added Ecto text helpers for common DuckDB string predicates and splitting functions.
- Added a public API audit for 0.4.0 and locked accepted naming decisions.
- Added `case_when` syntax for DuckDB `CASE WHEN` and atom date parts.
- Added ordered `list/2` and `string_agg/3` with NULL ordering.
- Added Ecto `count(..., :distinct)` and `coalesce/2` SQL generation.
- Added `arg_max/3`, `arg_min/3`, approximate aggregate, boolean aggregate, Bitwise-style bit aggregate, statistical, precise floating-point aggregate, weighted aggregate, product, and histogram helpers.
- Added value window functions with fragment-backed frames and future-ready window frame helper macros.
- Added direct and Ecto queryable `SUMMARIZE` profiling helpers.
- Added DuckDB function snapshot task with normalized QuackDB type specs for overload auditing.
- Added protocol coverage and quack-ts parity docs plus expanded type/null/append conformance coverage, including stricter variable-vector value count validation and nested dictionary/constant vector coverage.
- Added source sampling, JSON source composition, lakehouse workflow docs, metadata examples, ordinary Elixir map encoding for explicit DuckDB MAP append columns, enumerable stream append, and Table.Reader input append.

### Fixed

- Rejected malformed Quack logical type objects that omit required type ids, metadata type tags, or child type fields.

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

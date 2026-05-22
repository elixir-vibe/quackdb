# Changelog

## Unreleased

### Added

- Expanded read-only Ecto query generation with common aggregates, `like/2`, nil checks, and simple fragments.
- Added a DuckDB type support guide and real-server integration coverage for scalar and nested type families.
- Added UUID and ENUM result decoding.
- Added conservative client-side SQL parameter formatting for raw queries and Ecto pinned parameters.
- Added row-level and map-level streaming helpers for large result sets.
- Hardened streaming helper behavior around early halt, later fetch errors, and duplicate map column names.
- Added property tests for protocol reader/writer primitive roundtrips and malformed input handling.

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
- Ecto support is intentionally limited; joins, grouped queries, migrations, and Ecto-managed writes are not supported yet.

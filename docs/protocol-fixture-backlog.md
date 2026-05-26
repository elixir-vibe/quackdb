# Protocol fixture backlog

QuackDB keeps byte-for-byte quack-ts fixtures for representative scalar and nested append/data-chunk encoding. The next conformance expansion should add independently generated fixtures for the protocol shapes below before treating them as cross-implementation locked.

## High-priority fixtures

- `BIGNUM` values with positive, negative, zero, and very large magnitudes.
- `INTERVAL` values with months, days, and microseconds all non-zero.
- `TIME_NS` values preserving nanoseconds beyond Elixir `Time` microseconds.
- `TIMESTAMP_NS` values preserving nanoseconds beyond Elixir `NaiveDateTime` microseconds.
- `TIME WITH TIME ZONE` values with positive and negative offsets.
- `GEOMETRY` values from DuckDB Spatial, compared against `ST_AsWKB` output.
- Null-heavy nested vectors, especially lists/maps with empty, null, and non-empty rows in the same vector.

## Decode-side expectations

Every fixture should have two checks when possible:

1. QuackDB encoding matches the independent fixture byte-for-byte.
2. QuackDB decodes the independent fixture and either re-encodes byte-for-byte or asserts the decoded semantic values when an equivalent Elixir input shape cannot currently re-encode identically.

Nested `MAP` decode currently materializes map entries as Elixir maps, while append encoding accepts map entries as list-like key/value structures. Until those shapes are normalized, semantic decode assertions are more robust than byte-for-byte re-encode assertions for nested map fixtures.

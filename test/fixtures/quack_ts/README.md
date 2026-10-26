# quack-ts protocol fixtures

These binary fixtures were generated from the independent `quack-ts` implementation in `/tmp/quack-protocol` and are used as golden wire-format fixtures for QuackDB protocol conformance tests.

They predate DuckDB 2.0 and encode strings in the pre-2.0 list layout, which DuckDB 2.0 still reads. The ExUnit tests decode each fixture and compare its rows with QuackDB's own encoding of the same values; QuackDB now writes the 2.0 string layout, so there is no byte-for-byte encode parity. The TypeScript generator is intentionally not part of this repository; regenerate these fixtures from a checked-out quack-ts copy when the upstream protocol encoding changes.

Fixtures:

- `data_chunk_scalar.bin` — wrapped scalar `DataChunk` with integer, varchar, boolean, decimal, date, time, timestamp, timestamptz, and blob columns.
- `data_chunk_nested.bin` — wrapped nested `DataChunk` with list, struct, array, and map columns.
- `data_chunk_bignum_extra.bin` — wrapped `DataChunk` with zero, positive, and negative `BIGNUM` values.
- `data_chunk_temporal_extra.bin` — wrapped `DataChunk` with `TIME_NS`, `TIMESTAMP_NS`, `TIME WITH TIME ZONE`, and `INTERVAL` columns.
- `data_chunk_spatial_extra.bin` — wrapped `DataChunk` with a WKB-compatible `GEOMETRY` column.
- `data_chunk_nested_nulls_extra.bin` — wrapped nested `DataChunk` with null-heavy list, struct, and map columns.

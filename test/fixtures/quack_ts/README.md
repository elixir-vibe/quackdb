# quack-ts protocol fixtures

These binary fixtures were generated from the independent `quack-ts` implementation in `/tmp/quack-protocol` and are used as golden wire-format fixtures for QuackDB protocol conformance tests.

The ExUnit tests compare QuackDB's encoder output byte-for-byte against these files and also decode each fixture before re-encoding it to prove decode-side compatibility for the covered shapes. The TypeScript generator is intentionally not part of this repository; regenerate these fixtures from a checked-out quack-ts copy when the upstream protocol encoding changes.

Fixtures:

- `data_chunk_scalar.bin` — wrapped scalar `DataChunk` with integer, varchar, boolean, decimal, date, time, timestamp, timestamptz, and blob columns.
- `data_chunk_nested.bin` — wrapped nested `DataChunk` with list, struct, array, and map columns.
- `append_request_scalar.bin` — `APPEND_REQUEST` wrapping the scalar chunk for `main.events`.
- `append_request_nested.bin` — `APPEND_REQUEST` wrapping the nested chunk for `main.events`.
- `data_chunk_temporal_extra.bin` — wrapped `DataChunk` with `TIME_NS`, `TIMESTAMP_NS`, `TIME WITH TIME ZONE`, and `INTERVAL` columns.
- `data_chunk_spatial_extra.bin` — wrapped `DataChunk` with a WKB-compatible `GEOMETRY` column.
- `data_chunk_nested_nulls_extra.bin` — wrapped nested `DataChunk` with null-heavy list, struct, and map columns.

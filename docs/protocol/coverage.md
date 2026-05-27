# Quack protocol coverage

QuackDB is intentionally protocol-first, but it does not claim full DuckDB Quack protocol coverage yet. This matrix tracks the implemented surface, unsupported gaps, and the test style expected before a feature is treated as covered.

## Message coverage

| Quack message | Status | Coverage |
| --- | --- | --- |
| Connection request | Supported | Codec tests and connection integration |
| Connection response | Supported | Codec tests and connection integration |
| Prepare request | Supported | Query, prepare, and stream integration |
| Prepare response | Supported | Query, prepare, and stream integration |
| Fetch request | Supported | Streaming/fetch continuation tests |
| Fetch response | Supported | Streaming/fetch continuation tests |
| Append request | Supported | Native append integration and quack-ts encode fixtures |
| Success response | Supported | Append and disconnect paths |
| Error response | Supported | Query, append, and transport error tests |
| Disconnect | Supported | DBConnection disconnect cleanup |

## Vector encoding coverage

| Vector encoding | Decode | Encode | Notes |
| --- | --- | --- | --- |
| Flat | Supported | Supported | Primary query and append path |
| Constant | Supported | Not emitted | Decode expands constants to row values |
| Dictionary | Supported | Not emitted | Decode validates selection indexes |
| Sequence | Supported | Not emitted | Decode materializes generated values |
| FSST | Unsupported | Unsupported | Raises explicit `:unsupported_vector_type`; QuackDB has an internal optional `:fsst` bridge, but DuckDB currently flattens FSST vectors before Quack serialization and the compressed wire payload shape is not exposed by current DuckDB releases |
| Unknown vector ids | Unsupported | Unsupported | Raises explicit `:unknown_vector_type` |

## Logical type coverage

| DuckDB logical type family | Decode | Append encode | Notes |
| --- | --- | --- | --- |
| Booleans | Supported | Supported |  |
| Signed/unsigned integers | Supported | Supported | Includes hugeint/uhugeint |
| Floating point | Supported | Supported |  |
| Decimal | Supported | Supported | Width-dependent physical storage |
| VARCHAR/CHAR | Supported | Supported | Invalid UTF-8 raises explicit errors |
| BLOB | Supported | Supported | Raw bytes |
| UUID | Supported | Partial | Decode supported; append can encode integer storage but public UUID append ergonomics are not finalized |
| ENUM | Supported | Partial | Decode supported; append requires encoded enum index today |
| BIT | Supported | Partial | Decode to bit string; append expects DuckDB bit payload bytes |
| BIGNUM | Supported | Supported | Elixir integers; fixture covers zero, positive, and negative large values |
| DATE/TIME/TIMESTAMP/TIMESTAMPTZ | Supported | Supported | Calendar-aware append encoding |
| TIME_NS | Supported | Supported | `QuackDB.NanosecondTime` |
| TIMESTAMP_NS | Supported | Supported | `QuackDB.NanosecondTimestamp` |
| TIME WITH TIME ZONE | Supported | Supported | `QuackDB.TimeWithTimeZone` |
| INTERVAL | Supported | Supported | `QuackDB.Interval` |
| LIST | Supported | Supported | Nested values covered by real integration |
| STRUCT | Supported | Supported | String-key maps on decode |
| ARRAY | Supported | Supported | Fixed-size metadata is encoded/decoded |
| MAP | Supported | Supported | Decodes to maps; duplicate keys follow `Map.put/3` semantics |
| SQLNULL | Partial | Partial | Covered as ordinary null values, not all standalone logical-type edge cases |
| UNION | Unsupported | Unsupported | Should raise explicit unsupported errors |
| VARIANT | Unsupported | Unsupported | Should raise explicit unsupported errors |
| ANY/TEMPLATE/LAMBDA/POINTER | Unsupported | Unsupported | Protocol metadata reserved/unsupported |
| AGGREGATE_STATE | Unsupported | Unsupported | Metadata not implemented |
| Extension/custom types | Unsupported | Unsupported | Metadata not implemented |
| GEOMETRY | Partial | Partial | Decoded as WKB-compatible bytes from DuckDB spatial geometry values; semantic geometry structs are not implemented |

## DBConnection and client coverage

| Feature | Status | Coverage |
| --- | --- | --- |
| Query execution | Supported | Unit and integration |
| Prepare/execute | Supported | Unit and integration |
| Streaming/fetch continuation | Supported | Unit and integration |
| Transactions | Supported | Unit and integration |
| Native row append | Supported | Unit and integration |
| Native column append | Supported | Unit and integration |
| Ecto raw SQL | Supported | Unit and integration |
| Ecto analytical reads | Partial | Broad SQL-generation and integration coverage |
| Ecto insert/insert_all | Covered | Plain inserts, returning, insert-from-query, common upserts, `on_conflict: :nothing`, and explicit native append fast path covered |
| Ecto mutations and DDL | Partial | Schema update/delete, joined `update_all`, joined `delete_all`, rowid-filtered ordered/limited mutations, `Repo.explain`, transactions, and basic migrator-backed DDL covered where DuckDB SQL allows it |

## Conformance fixtures

Current cross-implementation fixtures compare QuackDB's append/data chunk encoding byte-for-byte with quack-ts for scalar and nested chunks. See [`fixtures.md`](docs/protocol/fixtures.md) for the fixture inventory, parity checklist, malformed fixtures, and fixture backlog.

## Next coverage targets

| Area | Next work |
| --- | --- |
| Real-server type matrix | Keep adding SQL-generated edge cases for standalone `NULL`, nested nullability, unsigned/huge values, temporal precision, and DuckDB extension types as they become stable over Quack. |
| Append roundtrips | Expand native append tests for null-heavy scalar/nested values, schema mismatch errors, and batch-boundary behavior. |
| Malformed vectors | Add targeted fixtures for missing required fields, invalid validity masks, malformed list entries, array-size mismatches, and unsupported compressed vectors. |
| Unsupported logical types | Add fixtures or synthetic metadata tests for `UNION`, `VARIANT`, extension/custom types, and aggregate state once stable payloads are available. |
| FSST | Capture a real DuckDB Quack FSST payload if DuckDB starts serializing compressed FSST vectors instead of flattened strings. |

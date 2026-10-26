# Quack protocol coverage

QuackDB is intentionally protocol-first, but it does not claim full DuckDB Quack protocol coverage yet. It speaks Quack protocol version 3, the version DuckDB 2.0 serves, and refuses servers that select another version. This matrix tracks the implemented surface, unsupported gaps, and the test style expected before a feature is treated as covered.

## Message coverage

| Quack message | Status | Coverage |
| --- | --- | --- |
| Connection request | Supported | Version 3 range, client id, and heartbeat lease; codec tests and connection integration |
| Connection response | Supported | Negotiated lease; DuckDB 2.0 fixture and integration |
| Prepare request | Supported | Query UUID and inline row limit; query, prepare, and stream integration |
| Prepare response | Supported | DuckDB 2.0 fixtures and integration |
| Fetch request | Supported | Dense batch and acknowledged-prefix indexes; retried after lost connections |
| Fetch response | Supported | Chunk blob after the body and terminal batch count; DuckDB 2.0 fixtures |
| Send-data request | Supported | Native appends into `scan_data_from_quack_client`; codec tests and integration |
| Send-data response | Supported | Native append integration |
| Cancel request | Supported | `QuackDB.cancel/3`, timeouts, and disconnects; integration |
| Acknowledgement | Supported | Sent with `acknowledge_results: true` |
| Heartbeat request | Supported | DBConnection idle pings; integration |
| Success response | Supported | Heartbeat, cancel, and disconnect paths |
| Error response | Supported | Message, exception type, extra info, and invalidation flag; DuckDB 2.0 fixture |
| Disconnect | Supported | DBConnection disconnect cleanup |

## Vector encoding coverage

| Vector encoding | Decode | Encode | Notes |
| --- | --- | --- | --- |
| Flat | Supported | Supported | Primary query and append path; strings use DuckDB 2.0's lengths-and-bytes layout and the pre-2.0 list layout still decodes |
| Constant | Supported | Not emitted | Decode expands constants to row values |
| Dictionary | Supported | Not emitted | Decode validates selection indexes |
| Sequence | Supported | Not emitted | Decode materializes generated values |
| Shredded | Supported | Not emitted | VARIANT columns read from storage; typed fields merge with unshredded leftovers |
| FSST | Unsupported | Unsupported | Raises explicit `:unsupported_vector_type`; QuackDB has an internal optional `:fsst` bridge, but current real-server probes with repeated long strings still return flat `VARCHAR` chunks over Quack, so the compressed wire payload shape is not exposed by current DuckDB releases |
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
| TIMESTAMPTZ_NS | Supported | Supported | `QuackDB.NanosecondTimestamp` holding the UTC instant |
| TIME WITH TIME ZONE | Supported | Supported | `QuackDB.TimeWithTimeZone` |
| INTERVAL | Supported | Supported | `QuackDB.Interval` |
| LIST | Supported | Supported | Nested values covered by real integration |
| STRUCT | Supported | Supported | String-key maps on decode |
| ARRAY | Supported | Supported | Fixed-size metadata is encoded/decoded |
| MAP | Supported | Supported | Decodes to maps; duplicate keys follow `Map.put/3` semantics |
| SQLNULL | Partial | Partial | Covered as ordinary null values, not all standalone logical-type edge cases |
| UNION | Unsupported | Unsupported | Should raise explicit unsupported errors |
| VARIANT | Supported | Via JSON | Decodes to Elixir terms, shredded or not; `:variant` append columns send JSON text that DuckDB casts |
| TUPLE | Supported | Unsupported | Decodes to Elixir tuples |
| ANY/TEMPLATE/LAMBDA/POINTER | Unsupported | Unsupported | Protocol metadata reserved/unsupported |
| LEGACY_AGGREGATE_STATE | Unsupported | Unsupported | Metadata not implemented |
| Extension/custom types | Unsupported | Unsupported | Metadata not implemented |
| GEOMETRY | Partial | Partial | Decoded as WKB-compatible bytes from DuckDB spatial geometry values; semantic geometry structs are not implemented |

## DBConnection and client coverage

| Feature | Status | Coverage |
| --- | --- | --- |
| Query execution | Supported | Unit and integration |
| Prepare/execute | Supported | Unit and integration |
| Streaming/fetch continuation | Supported | Unit and integration |
| Transactions | Supported | Unit and integration |
| Native row append | Supported | Unit and integration, including `ON CONFLICT`, `RETURNING`, and column defaults |
| Native column append | Supported | Unit and integration |
| Query cancellation | Supported | `QuackDB.cancel/3`; timeouts and disconnects cancel their query |
| Heartbeat leases | Supported | Idle pings renew; expired leases reconnect |
| Ecto raw SQL | Supported | Unit and integration |
| Ecto analytical reads | Partial | Broad SQL-generation and integration coverage |
| Ecto insert/insert_all | Covered | Plain inserts, returning, insert-from-query, common upserts, `on_conflict: :nothing`, and explicit native append fast path covered |
| Ecto mutations and DDL | Partial | Schema update/delete, joined `update_all`, joined `delete_all`, rowid-filtered ordered/limited mutations, `Repo.explain`, transactions, and basic migrator-backed DDL covered where DuckDB SQL allows it |

## Conformance fixtures

Golden fixtures captured from a real DuckDB 2.0 server cover the handshake, typed errors, prepare and fetch responses, and VARIANT layouts. The older quack-ts chunks remain as decode checks for the pre-2.0 string layout. See [`fixtures.md`](fixtures.md) for the fixture inventory and malformed fixtures.

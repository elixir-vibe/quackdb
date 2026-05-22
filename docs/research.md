# QuackDB Research

This document captures the initial research for an Elixir implementation of DuckDB's Quack remote protocol, designed for later Ecto consumption.

## Goal

Build a remote DuckDB client for Elixir that is:

- protocol-native, not CLI-backed;
- pure Elixir at the transport/codec layer where possible;
- structured around `DBConnection` so Ecto can consume it later;
- capable of streaming analytical result sets;
- explicit about protocol instability and unsupported DuckDB vector encodings.

Recommended package/module plan:

- Hex package: `quackdb_ex`
- Main namespace: `QuackDB`
- Future Ecto adapter package or module: `Ecto.Adapters.QuackDB`

## Primary sources

- DuckDB docs/blog: `Quack: The DuckDB Client-Server Protocol`
- DuckDB docs: Quack overview, reference, security, reverse proxy setup, WASM setup
- Source repo: `duckdb/duckdb-quack`, branch `v1.5-variegata`
- Protocol files:
  - `src/include/quack_message.json`
  - `src/include/quack_message.hpp`
  - `src/serialize_quack_message.cpp`
  - `src/quack_message.cpp`
  - `src/quack_server.cpp`
  - `src/quack_http_server.cpp`
  - `src/quack_client.cpp`
- Clean-room/community implementations:
  - `tobilg/quack-protocol` TypeScript client
  - `CurtHagenlocher/quack-net` .NET client
  - `gizmodata/adbc-driver-quack`
- Elixir adapter references:
  - `ecto_sqlite3`
  - old `ecto_duckdb`
  - `quack_lake`
  - `db_connection`
  - `ecto_sql`

## Quack protocol summary

Quack is an experimental DuckDB client/server protocol. The official extension lets DuckDB instances communicate over HTTP. It supports remote query execution, result fetching, append operations, token authentication, authorization callbacks, and multiple concurrent clients.

The protocol is HTTP-based but the body is not JSON. Requests are binary Quack messages using DuckDB's internal `BinarySerializer` conventions for objects, logical types, and `DataChunk`s.

### Transport

- Endpoint: `POST /quack`
- Default port: `9494`
- Request body: raw binary Quack message
- Practical request content type: `application/duckdb`
- Current C++ server may respond with `application/vnd.duckdb`
- `GET /` returns a plain-text hint
- Browser-oriented server CORS is broad:
  - `Access-Control-Allow-Origin: *`
  - `Access-Control-Allow-Methods: GET, POST, OPTIONS`
  - `Access-Control-Allow-Headers: *`

### Connection lifecycle

1. Send `CONNECTION_REQUEST` without a connection id.
2. Receive `CONNECTION_RESPONSE`; store `header.connection_id`.
3. Send `PREPARE_REQUEST` with the connection id.
4. Receive schema, initial result chunks, `needs_more_fetch`, and `result_uuid`.
5. If more data is needed, repeat `FETCH_REQUEST` with the same connection id and result UUID.
6. Send `DISCONNECT_MESSAGE` when closing.

Server state is in-memory and keyed by `connection_id`. Any message except `CONNECTION_REQUEST` requires a valid connection id. Invalid sessions return `ERROR_RESPONSE("Invalid connection id")`.

The server uses a per-connection mutex and stores one active query result per connection. A new prepare request resets prior result state.

### Message envelope

Every message contains:

1. `MessageHeader`
2. Message-specific body

Header fields:

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `type` | message type enum |
| 2 | `connection_id` | string |
| 3 | `client_query_id` | optional index |

Known message type ids:

| Id | Name |
| ---: | --- |
| 0 | `INVALID` |
| 1 | `CONNECTION_REQUEST` |
| 2 | `CONNECTION_RESPONSE` |
| 3 | `PREPARE_REQUEST` |
| 4 | `PREPARE_RESPONSE` |
| 7 | `FETCH_REQUEST` |
| 8 | `FETCH_RESPONSE` |
| 9 | `APPEND_REQUEST` |
| 10 | `SUCCESS_RESPONSE` |
| 11 | `DISCONNECT_MESSAGE` |
| 100 | `ERROR_RESPONSE` |

The server accepts only connection requests, prepare requests, fetch requests, append requests, and disconnect messages.

### Message bodies

#### `CONNECTION_REQUEST`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `auth_string` | string |
| 2 | `client_duckdb_version` | string |
| 3 | `client_platform` | string |
| 4 | `min_supported_quack_version` | u64/index |
| 5 | `max_supported_quack_version` | u64/index |

The current protocol version target is `1`.

#### `CONNECTION_RESPONSE`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `server_duckdb_version` | string |
| 2 | `server_platform` | string |
| 3 | `quack_version` | u64/index |

The negotiated connection id is in the header.

#### `PREPARE_REQUEST`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `sql_query` | string |

Despite the name, current implementations treat this as remote execution and return initial result chunks.

#### `PREPARE_RESPONSE`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `result_types` | list of DuckDB logical types |
| 2 | `result_names` | list of strings |
| 3 | `needs_more_fetch` | bool |
| 4 | `results` | list of nullable `DataChunkWrapper` pointers |
| 5 | `result_uuid` | hugeint |

#### `FETCH_REQUEST`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `uuid` | hugeint |

#### `FETCH_RESPONSE`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `results` | list of `DataChunkWrapper` |
| 2 | `batch_index` | optional index |

#### `APPEND_REQUEST`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `schema_name` | string |
| 2 | `table_name` | string |
| 3 | `append_chunk` | nullable `DataChunkWrapper` |

#### `SUCCESS_RESPONSE`

Empty object.

#### `DISCONNECT_MESSAGE`

Empty object.

#### `ERROR_RESPONSE`

| Field id | Name | Type |
| ---: | --- | --- |
| 1 | `message` | string |

There are no typed error codes in the protocol today, so the Elixir package should normalize server string errors into structured `%QuackDB.Error{}` values where possible.

## Binary serialization

Quack reuses DuckDB `BinarySerializer` semantics.

Important primitives:

- Object = ordered fields followed by end marker.
- Field id = `uint16` little-endian.
- End-of-object marker = `0xFFFF`.
- Required fields should appear as expected.
- Optional/default fields may be omitted.
- Bool = one byte, `0` or `1`.
- Unsigned integers = ULEB128.
- Signed integers = SLEB128.
- Strings/blobs = ULEB128 byte length + raw bytes.
- Lists = ULEB128 length + elements.
- Nullable pointer = bool-present flag + value when present.
- `optional_idx` absent sentinel = `0xFFFF_FFFF_FFFF_FFFF`.
- Message `hugeint` = signed upper half + unsigned lower half using LEB128.
- Fixed-width vector numeric payloads are little-endian.

The core Elixir codec should be isolated and testable independently from HTTP.

## Result chunks and vectors

`DataChunkWrapper` is an object with field `300` containing a `DataChunk`.

`DataChunk` fields:

| Field id | Meaning |
| ---: | --- |
| 100 | row count |
| 101 | list of logical types |
| 102 | list of vectors |

Known vector types:

| Id | Name |
| ---: | --- |
| 0 | `FLAT` |
| 1 | `FSST` |
| 2 | `CONSTANT` |
| 3 | `DICTIONARY` |
| 4 | `SEQUENCE` |

Recommended support order:

1. Flat vectors for scalar primitive types.
2. Validity masks.
3. Constant vectors.
4. Dictionary vectors.
5. Sequence vectors.
6. Nested list/array/struct/map types.
7. Append encoding.
8. FSST only if needed and spec/source behavior is clear.

Validity mask notes:

- Size = `ceil(row_count / 64) * 8` bytes.
- Set bit means valid.
- Bit index formula: `byte[index / 8] & (1 << (index % 8))`.

## Security

Server startup is done with DuckDB SQL like:

```sql
SELECT quack_serve('0.0.0.0:9494', token := '...', allow_other_hostname := true);
```

Relevant server behavior:

- A random token is generated unless supplied.
- Minimum token length is 4 characters.
- The server binds localhost by default.
- External host binding requires `allow_other_hostname := true`.
- Server does not terminate TLS; production should use a reverse proxy.
- Auth happens on `CONNECTION_REQUEST`.
- Authorization happens on every `PREPARE_REQUEST` and on append via the same authorization hook.

Client behavior should include:

- token support;
- HTTPS support;
- configurable Req/Finch transport options;
- clear warning/errors for non-local plain HTTP when appropriate;
- no assumption that connection ids can move between load-balanced upstreams.

## Ecto and DBConnection integration

The project should not start with an Ecto adapter. It should first implement a `DBConnection` driver because Ecto SQL already expects that shape.

Recommended layers:

```text
QuackDB
├── public client API
├── DBConnection-facing driver
├── HTTP transport
├── protocol message codec
├── logical type and vector codecs
├── result structs
└── future Ecto adapter
```

### DBConnection layer

Implement a module similar to `QuackDB.Connection` or `QuackDB.DBConnection` that uses `DBConnection` and handles:

- `connect/1`: send `CONNECTION_REQUEST`, store connection id and negotiated protocol version.
- `disconnect/2`: send `DISCONNECT_MESSAGE` if possible.
- `ping/1`: cheap `SELECT 1` or a protocol-level no-op if added later.
- `handle_prepare/3`: represent a query struct; Quack has no true server-side prepared statement yet.
- `handle_execute/4`: run SQL, collect or stream chunks.
- `handle_begin/2`, `handle_commit/2`, `handle_rollback/2`: execute `BEGIN`, `COMMIT`, `ROLLBACK` and track status.
- `handle_status/2`: return `:idle`, `:transaction`, or `:error`.
- `handle_declare/4`, `handle_fetch/4`, `handle_deallocate/4`: use Quack `result_uuid` fetch flow for streaming.

Result structs should satisfy Ecto SQL expectations:

```elixir
%QuackDB.Result{
  command: :select,
  columns: ["id", "name"],
  rows: [[1, "Ada"]],
  num_rows: 1,
  metadata: %{}
}
```

For command statements:

```elixir
%QuackDB.Result{command: :update, columns: nil, rows: nil, num_rows: affected_count}
```

### Ecto adapter layer

A later Ecto adapter should use:

```elixir
defmodule Ecto.Adapters.QuackDB do
  use Ecto.Adapters.SQL, driver: QuackDB.DBConnection
end
```

Required adapter pieces:

- `Ecto.Adapters.SQL.Connection` implementation for SQL generation and DBConnection bridge.
- `Ecto.Adapter.Storage` if `mix ecto.create/drop` should be supported.
- `Ecto.Adapter.Structure` if dump/load should be supported.
- `Ecto.Adapter.Migration` policy:
  - `supports_ddl_transaction?/0`
  - `lock_for_migrations/3`
- type mapping and DDL generation.
- constraint error mapping.
- explicit errors for unsupported Ecto features.

Best reference is `ecto_sqlite3` because it is complete and uses `?` placeholders, but DuckDB-specific SQL and types should not blindly inherit SQLite assumptions.

## Existing package landscape

| Package | Approach | Fit for this project |
| --- | --- | --- |
| `duckdbex` | active embedded DuckDB NIF | complementary local DuckDB option, not remote |
| `duckdb_ex` | DuckDB CLI wrapper with Python-like API | not ideal for DBConnection/Ecto semantics |
| `exduckdb` | old NIF via SQLite wrapper | historical only |
| `ecto_duckdb` | old Ecto adapter over `exduckdb` | prior art, not a remote protocol foundation |
| `quack_lake` | DuckLake management with Ecto adapters over `duckdbex` | modern reference, but DuckLake/local focused |
| `adbc` | Arrow ADBC bindings | possible optional result/backend integration later |
| `ex_arrow` | Arrow IPC/Flight/Flight SQL | useful for future Arrow interop, not Quack itself |

Differentiation:

> `quackdb_ex` is a remote DuckDB Quack protocol client, not an embedded driver, not a CLI wrapper, and not a DuckLake management library.

## Constraints and risks

- Quack is experimental and tied to DuckDB internal serialization.
- The public protocol spec is incomplete; the source and community clients are the practical spec.
- There is no bind-parameter message in the inspected protocol.
- No in-protocol cancellation exists.
- Error responses are string-only.
- FSST and some logical/vector types may need deferral.
- Load-balanced deployments require session affinity because connection state is server-local.
- Ecto expects row-oriented results and transaction semantics; Quack is more analytical/chunk-oriented.

## Implementation plan

### Phase 1: codec foundation

- Binary reader/writer for ULEB128, SLEB128, strings, blobs, booleans, field ids, object end markers.
- Header and message structs.
- Message encode/decode for connection, prepare, fetch, success, error, disconnect.
- Golden tests against bytes from TypeScript/.NET clients or local generated fixtures.

### Phase 2: HTTP client and session

- URI normalization for `quack://host:port`, `http://`, `https://`, and localhost defaults.
- `connect/1`, `disconnect/1`, `query/2`.
- Token authentication.
- Structured `%QuackDB.Error{}`.
- Integration tests against a running Quack server when available.

### Phase 3: result decoding

- Logical type decoder for common scalar types.
- DataChunk and flat vector decoding.
- Validity masks.
- Row materialization.
- Constant/dictionary/sequence vectors.
- Date/time/timestamp/decimal/UUID support.

### Phase 4: streaming

- Preserve `result_uuid` and fetch flow.
- `QuackDB.stream/3` with backpressure.
- DBConnection cursor callbacks.
- Chunk-size configuration.

### Phase 5: DBConnection driver

- Query struct and result struct.
- Connection lifecycle under DBConnection pooling.
- Transaction status tracking.
- Clear behavior on HTTP/server disconnects.
- Query timeouts.

### Phase 6: append and encoding

- Encode common scalar flat vectors.
- `append/4` for table ingestion.
- Optional Explorer/Arrow ingestion adapters later.

### Phase 7: Ecto adapter

- `Ecto.Adapters.QuackDB` using `Ecto.Adapters.SQL`.
- SQL generation based on DuckDB dialect.
- DDL/migrations.
- `Repo.all`, `Repo.insert`, `Repo.update`, `Repo.delete`, `Repo.query`.
- `Repo.stream` if DBConnection cursor support is complete.

## Testing strategy

- Codec unit tests with exact byte fixtures.
- Protocol roundtrip tests for every message type.
- Result decoding fixtures covering all vector encodings and logical types.
- Optional integration tests gated by `QUACKDB_TEST_URI` and `QUACKDB_TEST_TOKEN`.
- DBConnection behavior tests with a local server.
- Future Ecto adapter tests using an example repo and migrations.

## Initial public API sketch

```elixir
{:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", token: "secret")

{:ok, result} = QuackDB.query(conn, "SELECT 1 AS n")
#=> %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}

QuackDB.stream(conn, "SELECT * FROM large_table")
|> Stream.each(fn rows -> ... end)
|> Stream.run()
```

Future Ecto usage:

```elixir
defmodule MyApp.AnalyticsRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

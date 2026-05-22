# Postgrex comparison notes

These notes compare the current QuackDB implementation with Postgrex and capture implementation ideas worth borrowing.

## What Postgrex gets right

### Public API over DBConnection

Postgrex exposes a small public API while delegating ownership, pooling, queuing, and transactions to `DBConnection`:

- `Postgrex.query/4`
- `Postgrex.query!/4`
- `Postgrex.prepare/4`
- `Postgrex.prepare!/4`
- `Postgrex.prepare_execute/5`
- `Postgrex.execute/4`
- `Postgrex.stream/4`

The public functions build query structs and call `DBConnection.prepare_execute/4`, `DBConnection.execute/4`, or `DBConnection.reduce/3`.

**QuackDB implication:** the current GenServer client is fine for codec/protocol discovery, but the durable design should introduce a `DBConnection` driver early and make `QuackDB.query/4` a wrapper over DBConnection instead of a custom GenServer call.

### Query struct as protocol boundary

`Postgrex.Query` carries the stable query metadata:

- statement/name
- parameter types/formats
- result columns/types/formats
- type codec state
- cache/reference metadata

It implements `DBConnection.Query`:

- `parse/2`
- `describe/2`
- `encode/3`
- `decode/3`

**QuackDB implication:** add `%QuackDB.Query{}` now, even before Quack supports real bind parameters. It can carry:

- `statement`
- `columns`
- `result_types`
- `result_uuid`
- `needs_more_fetch?`
- `cache/ref` for future prepared-statement semantics

This gives Ecto/DBConnection a proper query term and avoids overloading raw strings.

### Result struct compatibility

`Postgrex.Result` is close to what Ecto SQL wants:

- `command`
- `columns`
- `rows`
- `num_rows`
- `connection_id`
- `messages`

It also implements `Table.Reader`, de-duplicating column names for table consumers.

**QuackDB implication:** extend `QuackDB.Result` with `connection_id` and `messages` eventually, and add `Table.Reader` when `table` is available. Keep `rows`/`num_rows` Ecto-shaped.

### Type codec architecture

Postgrex has a mature extension system:

- `Postgrex.Types`
- `Postgrex.Extension`
- per-type modules under `Postgrex.Extensions.*`
- cached type metadata in ETS

QuackDB does not need dynamic OID lookup, but the separation is valuable.

**QuackDB implication:** split the current large `DataChunk` decoder into smaller modules:

- `QuackDB.Protocol.LogicalType`
- `QuackDB.Protocol.Vector`
- `QuackDB.Protocol.Value`
- `QuackDB.Protocol.DataChunk`

Long term, type conversion should be configurable, e.g. dates as `Date` vs tagged raw structs, decimals as `Decimal` vs raw unscaled structs.

### Streaming design

Postgrex streaming is DBConnection-native:

- public `%Postgrex.Stream{}` implements `Enumerable`
- internally uses `DBConnection.Stream` / `DBConnection.PrepareStream`
- protocol implements `handle_declare/4`, `handle_fetch/4`, `handle_deallocate/4`

**QuackDB implication:** Quack's `result_uuid` maps naturally to a DBConnection cursor. `Repo.stream/2` later should use:

- `handle_declare`: send prepare request, store result UUID and first chunks
- `handle_fetch`: yield queued chunks, then send `FETCH_REQUEST`
- `handle_deallocate`: drain/close cursor state if needed

Current eager fetch-all behavior should remain `query/4`, but streaming should not materialize all rows.

### Transaction status and locks

Postgrex tracks connection state with `:idle | :transaction | :error` and also uses locked states like `{status, ref}` while a copy/cursor operation owns the connection. It rejects prepare/execute/commit/etc. while locked.

**QuackDB implication:** track:

- `status: :idle | :transaction | :error`
- optional `lock_ref` or cursor owner while a result UUID stream is open

This matters because Quack has one active query result per connection.

### Error structs and messages

Postgrex errors preserve structured server metadata and produce nice exception messages. Quack only has string errors today, but we can still normalize common cases.

**QuackDB implication:** enrich `%QuackDB.Error{}` with:

- `query`
- `connection_id`
- server message
- maybe `classification` derived from known string patterns, e.g. `:invalid_connection_id`, `:authorization_failed`

### Protocol modules are separate from public API

Postgrex separates:

- public `Postgrex`
- wire `Postgrex.Protocol`
- message records in `Postgrex.Messages`
- query/result structs
- type extensions

**QuackDB implication:** continue keeping codec modules independent from transport and DBConnection. Avoid putting HTTP, GenServer, and binary parsing in the same module.

## Gaps in QuackDB compared with Postgrex

Current QuackDB is still a discovery client. Missing Postgrex-inspired pieces:

1. DBConnection protocol module.
2. Query struct implementing `DBConnection.Query`.
3. Native stream struct implementing `Enumerable`.
4. Transaction callbacks and status tracking.
5. Query metadata preservation between prepare and execute.
6. Configurable type conversion.
7. Rich error metadata and exception messages.
8. Command detection/affected row handling.
9. Integration with `Table.Reader`.
10. A separate value/vector decoder module split.

## Implemented from this comparison

The first DBConnection-shaped core is now in place:

```text
lib/quack_db/query.ex
lib/quack_db/db_connection.ex
lib/quack_db/stream.ex
lib/quack_db/cursor.ex
```

Implemented pieces:

- `%QuackDB.Query{statement, columns, result_types, result_uuid}`.
- `DBConnection.Query` implementation with `decode_mapper` support.
- `QuackDB.DBConnection` with:
  - `connect/1`
  - `disconnect/2`
  - `ping/1`
  - `handle_prepare/3`
  - `handle_execute/4`
  - transaction callbacks via SQL `BEGIN`, `COMMIT`, `ROLLBACK`
  - initial cursor/stream callbacks backed by Quack `result_uuid`
- `QuackDB.query/4`, `prepare/3`, `prepare_execute/4`, and `stream/4` now use DBConnection.

Still worth improving:

- Add richer transaction tests against a real Quack server.
- Split vector decoding out of `DataChunk` once LIST/STRUCT/ARRAY support lands.


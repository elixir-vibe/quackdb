# Test coverage audit

This note compares QuackDB's current coverage with mature Elixir database adapters, mainly Postgrex and ecto_sqlite3, to identify what “good” coverage should look like for a DBConnection-backed DuckDB Quack client.

Reviewed on 2026-05-24.

## Baseline comparison

### Postgrex

Postgrex is a mature protocol driver, so it is the best local reference for driver-level coverage. Its tests are organized around behavioral areas rather than source modules:

- `query_test.exs` — broad query, encode/decode, prepared query, type, parameter, COPY, and edge-case coverage.
- `stream_test.exs` — cursor/stream lifecycle, chunking, early halt, nested streams, connection recovery after stream failures.
- `transaction_test.exs` — strict transaction mode, savepoints, rollback behavior, failed transaction states, disconnect-on-error behavior.
- `login_test.exs` — auth, connection options, env defaults, sockets, SSL, endpoints, connect failures.
- `error_test.exs` — error message shape, query context, notices/messages, server-raised errors.
- `alter_test.exs`, `schema_test.exs`, `type_server_test.exs`, `type_module_test.exs`, `custom_extensions_test.exs` — type extension and schema reload behavior.
- `notification_test.exs`, `replication_connection_test.exs` — PostgreSQL-specific advanced protocol features.

Approximate local count: **423 tests**.

Postgrex coverage style:

- Many tests hit a real database, not just fixtures.
- Protocol behavior is validated through public API outcomes.
- Error paths are first-class: bad auth, bad connection options, bad query states, failed stream states, failed transaction states.
- Connection recovery is repeatedly asserted after failures.
- Prepared query behavior is tested across named/unnamed modes, reuse, close, stale query structs, and cross-connection usage.
- Stream tests focus on lifecycle semantics, not just successful enumeration.
- Transaction tests cover invalid manual `BEGIN`/`ROLLBACK`, rollback after server errors, savepoint semantics, and connection status invariants.

### ecto_sqlite3

ecto_sqlite3 is useful as an Ecto adapter reference. Its coverage includes:

- adapter-specific storage lifecycle (`storage_up`, `storage_down`), autogeneration, dump commands;
- integration CRUD tests with schemas;
- blob/json/math/timestamp/uuid type behavior;
- streaming behavior;
- migration/support schema setup.

It validates the adapter through Ecto's public `Repo` APIs, schemas, migrations, and integration tests rather than only testing SQL generation.

## QuackDB current coverage

QuackDB currently has a strong foundation for a young driver:

- low-level protocol reader/writer tests and properties;
- codec tests for core message families;
- vector decoding tests for flat, dictionary, sequence, scalar, and nested vectors;
- real DuckDB Quack integration tests for query, fetch, streaming, transactions, errors, Ecto raw queries, Ecto analytical reads, source helpers, columnar APIs, and Explorer conversion paths;
- type matrix coverage for many scalar and nested DuckDB types;
- SQL parameter literal formatting tests;
- source helper tests;
- result/inspect tests.

Approximate local count after the 0.1.1 work: **121 tests + 8 properties**.

This is good for protocol discovery and early package confidence, but it is not yet “mature adapter” coverage.

## Biggest gaps versus mature adapters

### 1. Connection lifecycle and auth failures

Postgrex has extensive login/connection tests. QuackDB currently has `ping/2` and happy-path connection coverage, but needs a dedicated lifecycle suite.

Add tests for:

- server unavailable / refused connection;
- invalid URI and unsupported URI schemes;
- bad token / unauthorized Quack connection;
- HTTP non-200 responses;
- HTTP timeout;
- malformed connection response;
- connection response error message shape;
- server version/platform metadata persistence;
- `disconnect` behavior if/when Quack disconnect messages are implemented;
- pool checkout behavior when connect fails;
- recovery after a failed initial connect.

Suggested file:

- `test/quack_db/connection_lifecycle_test.exs`
- real-server variants in `test/quack_db/integration/connection_lifecycle_test.exs`

### 2. Stream lifecycle and recovery

Current stream coverage includes chunking, row/map helpers, early halt, and later fetch errors. Postgrex goes deeper.

Add tests for:

- streaming a prepared query after the same query was executed normally;
- streaming the same prepared query more than once;
- stream with a query prepared on a different connection should error clearly or re-prepare intentionally;
- nested streams inside a transaction;
- stream failure during initial prepare/open leaves connection usable;
- stream failure during later fetch leaves connection usable or disconnects intentionally;
- early halt closes/deallocates server cursor when protocol supports it;
- fetch result UUID mismatch;
- fetch after server reports no more chunks;
- empty stream result behavior;
- `max_rows` validation.

Suggested file:

- split current stream tests out of `db_connection_test.exs` into `test/quack_db/stream_test.exs`.

### 3. Transaction state machine coverage

QuackDB supports `BEGIN`, `COMMIT`, and `ROLLBACK`, but does not yet have Postgrex-style transaction state coverage.

Add tests for:

- successful commit;
- explicit rollback;
- server error inside transaction followed by rollback;
- server error inside transaction followed by commit;
- manual `BEGIN` inside `DBConnection.transaction/3`;
- manual `ROLLBACK` inside `DBConnection.transaction/3`;
- failed `BEGIN`;
- failed `COMMIT`;
- failed `ROLLBACK`;
- connection usability after each of the above;
- nested transaction behavior and explicit unsupported savepoint semantics if not implemented.

Suggested file:

- `test/quack_db/transaction_test.exs`
- gated real-server variants.

### 4. Ecto adapter integration depth

QuackDB now has broad SQL generation for analytical Ecto reads, but most Ecto tests are still string-generation checks. Mature adapter coverage should validate public `Repo` behavior.

Add real or fixture-backed Repo tests for:

- `Repo.one/2`;
- `Repo.exists?/2`;
- `Repo.aggregate/4`;
- schema-backed sources, not only table-name strings;
- prefixes / attached schemas if DuckDB semantics are clear;
- subqueries in `where`, `select`, and `join`;
- `selected_as/2` and ordering by selected aliases;
- `parent_as/1` if correlated subqueries are added;
- `in` subqueries, empty `in []`, pinned lists;
- `is_nil`, `not`, boolean columns;
- multiple joins and join qualifiers;
- CTEs with params;
- fragments with params in source and select positions;
- unsupported migrations/write operations through actual `Repo` calls, not just adapter functions.

Suggested files:

- `test/quack_db/ecto_sql_generation_test.exs`
- `test/quack_db/integration/ecto_read_test.exs`
- `test/quack_db/integration/ecto_unsupported_test.exs`

### 5. Type coverage needs encode/decode and source-derived cases

The real type matrix is a major strength. Missing mature-driver-style coverage includes:

- parameter formatting for every supported public parameter type against a real server;
- type values coming from CSV/Parquet/JSON sources, not only direct `SELECT` literals;
- nullability in every nested family;
- duplicate field names or unusual struct names where DuckDB permits them;
- BIGNUM once implemented;
- `TIME WITH TIME ZONE` validation;
- `UNION` and `VARIANT` if Quack exposes them;
- GEOMETRY via SQL-side conversion or explicit unsupported behavior;
- interval representation decision and compatibility tests.

Suggested expansion:

- keep `type_matrix_test.exs`, but add sections for “from source” and “parameter roundtrip”.

### 6. Error message contract

Postgrex explicitly checks formatted error messages, query context, notices, and connection IDs. QuackDB has basic server error propagation tests but needs a clearer contract.

Add tests for:

- `Exception.message/1` with query and connection context;
- transport errors versus server errors;
- malformed protocol errors;
- error metadata fields;
- messages/notices preservation when DuckDB returns warnings/messages;
- no loss of rows when messages are present;
- error inspect output.

Suggested file:

- `test/quack_db/error_test.exs`.

### 7. Prepared query semantics

Postgrex has heavy coverage for query structs and prepared statement lifecycle. QuackDB has `prepare` and `prepare_execute`, but not much lifecycle coverage.

Add tests for:

- `prepare/3` metadata;
- `execute/4` on prepared query;
- stale prepared query after connection restart;
- prepared query from another connection;
- named query behavior if names become meaningful;
- changed SQL with same name if names become meaningful;
- executing prepared query with params;
- prepared query inspect output with metadata.

### 8. Optional integrations

Explorer integration is currently tested when Explorer is available. Add fallback coverage for missing optional dependencies by compiling/test env without Explorer, or by moving the check into a tiny helper that can be unit-tested without unloading modules.

Also add tests for Explorer conversion edge cases:

- duplicate columns;
- empty result;
- command result;
- nested values accepted/rejected by Explorer;
- Decimal values;
- Date/Time/NaiveDateTime/DateTime values.

## Recommended next test roadmap

### Phase 1: DB driver hardening

1. Create `connection_lifecycle_test.exs`.
2. Create `transaction_test.exs`.
3. Create `stream_test.exs` and move/expand stream lifecycle tests.
4. Create `error_test.exs`.

This brings QuackDB closer to Postgrex's reliability profile.

### Phase 2: Ecto public behavior

1. Split SQL generation tests from Repo behavior tests.
2. Add real-server `Repo.one`, `Repo.exists?`, `Repo.aggregate`, schema source, subquery, and pinned-list cases.
3. Add actual unsupported-operation tests through `Repo` APIs.

This brings QuackDB closer to Ecto adapter expectations.

### Phase 3: Advanced DuckDB-specific coverage

1. Source-derived type tests for CSV/Parquet/JSON.
2. Lakehouse smoke tests that are skipped unless extensions/secrets are configured.
3. Cloud/object-store tests behind env vars.
4. Explorer edge-case conversion tests.

## What “good” should mean for QuackDB

QuackDB should not try to copy Postgrex feature-for-feature. Postgrex is PostgreSQL-specific and much older. But it should copy these principles:

- real server tests for every important public behavior;
- fixture/protocol tests for malformed wire inputs that are hard to trigger from a server;
- explicit recovery assertions after failures;
- transaction and stream state-machine tests;
- public API tests over implementation detail tests;
- unsupported features tested as stable, helpful errors;
- adapter tests through `Repo`, not only SQL string generation;
- source/file/lakehouse workflows treated as first-class DuckDB behavior.

## Immediate high-value additions

If we only add 10–15 tests next, add these:

1. bad token connection failure;
2. server unavailable connection failure;
3. malformed connection response;
4. HTTP timeout;
5. connection usable after query error;
6. connection usable after stream fetch error, or intentional disconnect documented;
7. failed `COMMIT` behavior;
8. failed `ROLLBACK` behavior;
9. `Repo.one` real-server query;
10. `Repo.aggregate` real-server query;
11. schema-backed source real-server query;
12. subquery source real-server query;
13. Ecto CTE with pinned params;
14. Explorer duplicate-column conversion;
15. source-derived Parquet type test.

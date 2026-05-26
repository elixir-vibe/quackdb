# Proposed test structure

QuackDB should use a test tree that mirrors its architecture and separates three concerns:

1. pure protocol/codec behavior that never needs a server;
2. DBConnection and public API behavior that can run against fixture transports;
3. real DuckDB Quack semantics that require a running server.

The goal is not to maximize directories. The goal is that a failing test tells us what layer broke.

## Recommended tree

```text
test/
  test_helper.exs

  support/
    quack_server.ex
    transports.ex
    protocol_fixtures.ex
    ecto_repo.ex
    schemas/
      event.ex
      category.ex

  quack_db/
    public_api_test.exs
    uri_test.exs
    sql_test.exs
    source_test.exs
    result_test.exs
    columns_test.exs
    inspect_test.exs
    optional_integrations/
      explorer_test.exs

    protocol/
      reader_writer_test.exs
      reader_writer_property_test.exs
      codec_test.exs
      messages_test.exs
      logical_type_test.exs
      value_test.exs
      data_chunk_test.exs
      vector_test.exs
      vector_dictionary_test.exs
      vector_sequence_test.exs
      vector_nested_test.exs
      scalar_decoding_test.exs
      malformed_input_test.exs

    db_connection/
      connect_test.exs
      query_test.exs
      prepare_execute_test.exs
      stream_test.exs
      transaction_test.exs
      error_test.exs
      lifecycle_test.exs

    ecto/
      sql_generation/
        select_test.exs
        joins_test.exs
        aggregates_test.exs
        windows_test.exs
        ctes_test.exs
        subqueries_test.exs
        sources_test.exs
        unsupported_test.exs
      repo/
        query_test.exs
        read_test.exs
        transaction_test.exs
        unsupported_test.exs

    integration/
      quack_server_test.exs
      connection_lifecycle_test.exs
      query_test.exs
      stream_test.exs
      transaction_test.exs
      error_test.exs
      type_matrix_test.exs
      source_files_test.exs
      ecto_read_test.exs
      ecto_transaction_test.exs
      explorer_test.exs
      cloud_sources_test.exs
      lakehouse_test.exs
```

## What belongs where

### `test/support`

Shared helpers should be boring and explicit.

- `protocol_fixtures.ex`: binary protocol response builders and fixture chunks.
- `transports.ex`: reusable fake transports such as happy path, server error, malformed response, timeout, streaming fetch sequence.
- `quack_server.ex`: gated real-server helpers, env parsing, skip messages, temp file helpers.
- `ecto_repo.ex`: test repos only. Keep repo definitions out of individual test files once coverage grows.
- `schemas/`: tiny Ecto schemas used by schema-backed source tests.

This avoids every test file defining its own transport and repo modules.

### `test/quack_db/public_api_test.exs`

Tests the top-level `QuackDB` module with fixture transports:

- `query/4`, `query!/4`;
- `prepare/3`, `prepare_execute/4`;
- `stream/4`, `rows/4`, `maps/4` only at API smoke level;
- `columns/4`, `columnar/4`, `column_batches/4`, `columnar_batches/4`;
- `ping/2`.

Detailed behavior belongs in the DBConnection subfolder.

### `test/quack_db/protocol`

Pure wire-level tests. These must not start DBConnection or hit HTTP.

Subdivide by protocol concept:

- `reader_writer_*`: primitive binary encoding and properties.
- `codec_test`: message envelope encode/decode.
- `messages_test`: individual message structs and required fields.
- `logical_type_test`: logical type metadata decoding.
- `value_test`: scalar value conversion.
- `data_chunk_test`: chunk-level decoding.
- `vector_*`: vector families, including flat/constant/dictionary/sequence/nested.
- `malformed_input_test`: truncated payloads, invalid field ids, impossible vector layouts, invalid UTF-8, bad type ids.

This is QuackDB's replacement for Postgrex's deep protocol tests.

### `test/quack_db/db_connection`

Fixture-transport tests for DBConnection behavior. These should be fast and deterministic.

Suggested files:

- `connect_test.exs`
  - connect request shape;
  - token/header behavior;
  - connection metadata;
  - malformed connection responses;
  - connect errors.

- `query_test.exs`
  - query metadata;
  - command normalization;
  - params formatting at DBConnection path;
  - decode mapper;
  - messages preservation.

- `prepare_execute_test.exs`
  - prepared query metadata;
  - executing prepared query;
  - prepared query from wrong connection if relevant;
  - stale result UUID behavior.

- `stream_test.exs`
  - chunking;
  - early halt;
  - later fetch error;
  - nested streams;
  - repeated streams;
  - stream after normal query;
  - max rows validation.

- `transaction_test.exs`
  - begin/commit/rollback statements;
  - rollback callback;
  - failed begin/commit/rollback;
  - connection usability after each failure;
  - nested transaction semantics.

- `error_test.exs`
  - server error message shape;
  - transport error shape;
  - protocol error shape;
  - query/connection context;
  - inspect output.

- `lifecycle_test.exs`
  - unavailable server transport;
  - timeout transport;
  - reconnect/recovery expectations;
  - pool concurrency with fake transport.

This layer is where QuackDB should copy Postgrex's seriousness most closely.

### `test/quack_db/ecto/sql_generation`

Pure SQL generation tests for the QuackDB Ecto connection SQL-generation callbacks.

These should not start a Repo. Their job is to pin the generated SQL.

Break current `ecto_adapter_test.exs` apart:

- `select_test.exs`: basic select, where, order, limit, offset.
- `joins_test.exs`: inner/left/right/full/cross, multiple joins, join predicates.
- `aggregates_test.exs`: count/sum/avg/min/max, filter, group/having.
- `windows_test.exs`: named windows, inline windows, row_number/rank/dense_rank, aggregate over windows.
- `ctes_test.exs`: simple CTE, recursive keyword, params inside CTEs, multiple CTEs.
- `subqueries_test.exs`: source subqueries, `in` subqueries, nested selects once supported.
- `sources_test.exs`: table names, source helpers, fragments, source aliases.
- `unsupported_test.exs`: combinations, locks, writes, migrations, any known unsupported shape.

This keeps analytical query growth manageable.

### `test/quack_db/ecto/repo`

Fixture-backed or real-ish Repo tests that exercise Ecto public APIs.

These test adapter integration, not just SQL strings:

- `query_test.exs`: `Repo.query/3`, params, command results.
- `read_test.exs`: `Repo.all`, `Repo.one`, `Repo.exists?`, `Repo.aggregate` once supported.
- `transaction_test.exs`: `Repo.transaction`, `Repo.rollback`, rollback after server errors.
- `unsupported_test.exs`: migrations, writes, unsupported query shapes through public Repo functions.

Some can use fake transports. Server-semantic cases should also appear under `integration`.

### `test/quack_db/integration`

Gated real DuckDB Quack tests. These should validate server semantics, not duplicate every fixture test.

Use tags:

- `@moduletag :integration` for all.
- More specific tags when useful: `:cloud`, `:lakehouse`, `:s3`, `:azure`, `:gcs`, `:explorer`.

Suggested files:

- `quack_server_test.exs`: minimal smoke tests only. This file should shrink over time.
- `connection_lifecycle_test.exs`: bad token, bad URL, unavailable server, timeout if practical.
- `query_test.exs`: scalar query, params, command results, messages if available.
- `stream_test.exs`: large fetch, chunking, early halt, fetch errors if triggerable.
- `transaction_test.exs`: commit, rollback, error in transaction, failed transaction recovery.
- `error_test.exs`: syntax errors, unsupported types, query context.
- `type_matrix_test.exs`: type families.
- `source_files_test.exs`: CSV, JSON, Parquet, XLSX if extension available.
- `ecto_read_test.exs`: real `Repo.all`, `Repo.one`, aggregate, joins, CTEs, windows.
- `ecto_transaction_test.exs`: real Ecto transactions and rollback.
- `explorer_test.exs`: query/source to Explorer DataFrame if Explorer loaded.
- `cloud_sources_test.exs`: opt-in env-var tests for S3/R2/GCS/Azure.
- `lakehouse_test.exs`: opt-in env-var tests for Delta/Iceberg/Lance/DuckLake.

Integration files should use helper functions from `support/quack_server.ex` for temp tables/files and skip messages.

## Naming conventions

Use behavior names, not implementation names, for high-level tests:

- good: `stream_test.exs`, `transaction_test.exs`, `connection_lifecycle_test.exs`
- avoid: `db_connection_callbacks_test.exs`

Use implementation names only for pure internals:

- `protocol/vector_test.exs`
- `protocol/reader_writer_test.exs`

## Tagging strategy

Recommended tags:

```elixir
@moduletag :integration
@moduletag :cloud
@moduletag :lakehouse
@moduletag :explorer
```

Default `mix test` should run:

- pure protocol tests;
- fixture DBConnection tests;
- SQL generation tests;
- optional integration tests only when deps are compiled but not external services.

Default `mix ci` should continue excluding external real-server integration unless explicitly configured.

Add aliases later:

```elixir
ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]
integration: ["test --include integration"]
```

## Migration from current tree

Current tree is good enough for 0.1.x but will become crowded. Suggested migration order:

1. Move fake transports into `test/support/transports.ex`.
2. Move test repos into `test/support/ecto_repo.ex`.
3. Split `test/quack_db/db_connection_test.exs` into:
   - `db_connection/query_test.exs`
   - `db_connection/stream_test.exs`
   - `db_connection/transaction_test.exs`
   - `db_connection/error_test.exs`
4. Split `test/quack_db/ecto_adapter_test.exs` into:
   - `ecto/sql_generation/*`
   - `ecto/repo/*`
5. Split `integration/quack_server_test.exs` by behavior once new tests are added.
6. Keep old filenames only as temporary shells if needed; avoid giant catch-all files.

## What not to do

- Do not put all real-server tests in `quack_server_test.exs` forever.
- Do not mix SQL generation assertions and Repo execution assertions in one file.
- Do not hide protocol malformed-input tests behind real-server tests; real servers rarely emit malformed data.
- Do not make cloud/lakehouse tests required by default.
- Do not create a directory per module if behavior-oriented grouping is clearer.

## Ideal end state

A mature QuackDB test tree should make these commands feel meaningful:

```sh
mix test test/quack_db/protocol
mix test test/quack_db/db_connection
mix test test/quack_db/ecto/sql_generation
mix test test/quack_db/ecto/repo
mix test --include integration test/quack_db/integration
```

A maintainer should be able to infer the broken layer from the path alone.

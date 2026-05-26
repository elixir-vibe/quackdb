# DuckDB capability survey for QuackDB

This note captures DuckDB features that are worth designing for in QuackDB beyond basic `SELECT`/`INSERT` and scalar results. It is based on the current DuckDB documentation reviewed on 2026-05-22.

QuackDB does not need to reimplement these features. The Quack server executes DuckDB SQL, so most support is about exposing safe Elixir helpers, preserving result fidelity, documenting server-side extension requirements, and avoiding protocol choices that make analytical workloads awkward later.

## High-leverage file and object-store scans

### Parquet datasets

DuckDB treats Parquet as a first-class analytical format:

```sql
SELECT * FROM 'test.parquet';
SELECT * FROM read_parquet(['file1.parquet', 'file2.parquet']);
SELECT *, filename FROM read_parquet('s3://bucket/path/*.parquet');
DESCRIBE SELECT * FROM 'test.parquet';
SELECT * FROM parquet_metadata('test.parquet');
```

Important capabilities to preserve or wrap:

- Multiple paths, lists of paths, and globs.
- `filename` and `file_row_number` virtual columns.
- Hive partition discovery via `hive_partitioning`.
- Schema reconciliation via `union_by_name`.
- Explicit schema override using Parquet field IDs.
- Projection and filter pushdown into Parquet row groups.
- Metadata table functions: `parquet_metadata`, `parquet_file_metadata`, `parquet_kv_metadata`, `parquet_schema`.
- Encrypted Parquet via `encryption_config`.
- `COPY ... TO ... (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE ..., KV_METADATA ..., PARQUET_VERSION 'V2')`.
- Whole-database `EXPORT DATABASE ... (FORMAT parquet)`.

QuackDB opportunity:

- Add documentation examples for remote Parquet queries over Quack.
- Add a small `QuackDB.Source.parquet/2` SQL-fragment builder that safely formats path/list/options rather than asking users to hand-build complex nested DuckDB option syntax.
- Keep row streaming stable, but leave room for a future columnar/Arrow path because Parquet workloads can be large and column-oriented.

### CSV, including hostile/faulty CSVs

DuckDB’s CSV reader is much more powerful than a casual CSV import:

```sql
SELECT * FROM 'flights.csv';
SELECT * FROM read_csv('flights.csv', delim = '|', header = true, columns = {'FlightDate': 'DATE'});
COPY table_name FROM 'flights.csv';
```

Notable options:

- Auto-detection via CSV sniffer.
- Explicit `columns`, `names`, `types`, and `auto_type_candidates`.
- Encodings: UTF-8, UTF-16, Latin-1; other encodings via `encodings` extension.
- Compressed CSV: `gzip` and `zstd`.
- Nonstandard delimiters up to 4 bytes, including emoji.
- Locale-ish parsing via `decimal_separator`, `thousands`, `dateformat`, `timestampformat`.
- Fault tolerance: `ignore_errors`, `strict_mode`, `null_padding`.
- Reject capture: `store_rejects`, `rejects_scan`, `rejects_table`, `rejects_limit`.
- Multi-file schema combination via `union_by_name`.
- Hive partition columns from paths.

QuackDB opportunity:

- Provide examples for `store_rejects` followed by querying reject tables through the same connection.
- Add fixture/integration tests for option values that produce nested DuckDB option types (`STRUCT`, lists) so parameter formatting remains safe.

### JSON as data source and type

DuckDB can auto-load JSON support and use JSONPath/JSON Pointer extraction:

```sql
SELECT * FROM 'todos.json';
SELECT * FROM read_json('todos.json', format = 'array', columns = {id: 'UBIGINT'});
SELECT j->'$.family', j->>'$.family' FROM example;
COPY todos TO 'todos.json';
```

Notable details:

- JSON files can be read directly or via `read_json`.
- `COPY` can import/export JSON.
- DuckDB has a real `JSON` type.
- JSONPath is intentionally limited to lookups, array indexing, wildcard, and reverse indexing.
- JSON uses 0-based indexing, unlike DuckDB `LIST`/`ARRAY` indexing.
- Since DuckDB 1.3.0, JSON reader returns a `filename` virtual column.

QuackDB opportunity:

- Validate `JSON` logical type over Quack. If Quack exposes it as `VARCHAR`, document that. If it has a specific logical type id, add decoder coverage.
- Add examples combining `QuackDB.maps/4` with JSON extraction for API/log analytics.

## Cloud storage and secrets

### HTTP(S) files

The `httpfs` extension lets DuckDB query files over HTTP(S):

```sql
SELECT * FROM 'https://domain.tld/file.parquet';
```

Key behavior:

- Works for files supported by DuckDB and loaded extensions.
- HTTP(S) access is read-only.
- Parquet supports partial reads using metadata plus HTTP range requests, so filtering/projection can avoid downloading the whole file.

### S3-compatible object stores

DuckDB’s `httpfs` supports S3 API reads/writes/globs:

```sql
CREATE OR REPLACE SECRET secret (
  TYPE s3,
  PROVIDER credential_chain
);

SELECT * FROM 's3://bucket/file.parquet';
SELECT * FROM read_parquet('s3://bucket/folder*/100?/t[0-9].parquet');
COPY table_name TO 's3://bucket/out/file.parquet';
```

Supported/interesting features:

- AWS S3, MinIO, Google Cloud interoperability, lakeFS; likely R2/Tigris if S3-compatible.
- Public/private reads, ListObjectsV2-backed globbing, multipart upload writes.
- Credential secrets via `config` and `credential_chain` providers.
- Credential chains can use `config`, `sts`, `sso`, `env`, `instance`, `process`.
- Secret parameters include endpoint, region, session token, URL style, SSL verification, requester pays, KMS key id.
- Special `R2` and `GCS` secret types.
- Hive partitioning works with HTTP(S) and S3 endpoints.
- Partitioned writes to S3 with `COPY ... PARTITION_BY (...)`.

QuackDB opportunity:

- Add a dedicated secret-execution helper or documentation patterns for creating secrets without logging credentials in application logs.
- Avoid client-side interpolation helpers that encourage embedding cloud secrets directly in SQL strings unless they are explicit and well documented.
- Consider a high-level source builder that accepts `s3://`, `r2://`, `gcs://`, `gs://`, `az://`, and normal HTTPS paths.

## Lakehouse and table formats

DuckDB now has first-class support for DuckLake, Iceberg, Delta, and Lance. The docs describe native DuckDB extensions with meaningful pushdowns and metadata handling.

### Delta Lake

```sql
SELECT * FROM delta_scan('s3://some/delta/table');
ATTACH 's3://bucket/delta-table' AS my_table (TYPE delta);
INSERT INTO my_table SELECT * FROM other_table;
SELECT * FROM my_table AT (VERSION => 5);
CHECKPOINT my_table;
```

Supported by the `delta` extension:

- Read and write local or remote Delta tables.
- S3, Azure Blob Storage, and GCS access using DuckDB secrets.
- Multithreaded scans and Parquet metadata reading.
- Data skipping/filter pushdown at row-group and file/partition levels.
- Projection pushdown.
- Deletion vectors.
- Primitive types, structs, and `VARIANT`.
- Blind appends via `INSERT INTO`.
- Time travel via `AT (VERSION => n)` or attach-time `VERSION`.
- Checkpointing attached Delta tables.

Gaps/risks:

- Credential chain behavior may differ because Delta uses `delta-kernel-rs`/`object_store` for some network operations.
- Platform support is extension-dependent.

### Iceberg

```sql
SELECT count(*) FROM iceberg_scan('s3://bucket/table/metadata/v1.metadata.json');
SELECT * FROM iceberg_metadata('data/iceberg/table', allow_moved_paths = true);
SELECT * FROM iceberg_snapshots('data/iceberg/table');
```

Important capabilities:

- Auto-installed/loaded on first use.
- Scans local and object-store tables with `httpfs`/`azure`.
- Snapshot selection via `snapshot_from_id` and `snapshot_from_timestamp`.
- Metadata and snapshot inspection table functions.
- Version hint handling and configurable metadata naming conventions.
- REST catalog support exists separately for fuller write support.

Notable warnings:

- Unsafe version guessing can violate ACID constraints.
- Some v3 and geometry cases are unsupported.

### DuckLake and Lance

The lakehouse support matrix lists DuckLake, Iceberg, Delta, and Lance as first-class formats. Highlights:

- DuckLake: read/write, deletes, updates, upserts, create/alter/rename, partitions, catalog attach, maintenance, encryption, table properties, time travel, change queries.
- Lance: read/write, deletes, updates, upserts, create table, catalog attach, column rename/add/drop/type changes, maintenance.
- Delta: strong read, write, catalog attach, time travel; no deletes/updates/upserts/create table in the matrix.
- Iceberg: read/write, deletes/updates, create table, catalog attach, time travel; fewer schema/table alteration operations in the matrix.

QuackDB opportunity:

- Treat these primarily as SQL/documentation features initially.
- Add integration guide snippets, not adapter abstractions, until the core protocol is very stable.
- Ensure type decoders cover `VARIANT`, nested structs/lists/maps, and any lakehouse-specific logical types encountered through Quack.

## Excel and office-style data

The `excel` extension can read/write `.xlsx` files and format numbers using Excel formatting rules:

```sql
INSTALL excel;
LOAD excel;
SELECT * FROM 'test.xlsx';
SELECT * FROM read_xlsx('test.xlsx', header = true, sheet = 'Sheet1', range = 'A1:B2');
COPY table_name TO 'out.xlsx' WITH (FORMAT xlsx, HEADER true, SHEET 'Report');
SELECT excel_text(1_234_567.897, 'h:mm AM/PM');
```

Notable options:

- `.xlsx` supported; `.xls` not supported.
- `header`, `sheet`, `range`, `all_varchar`, `ignore_errors`, `stop_at_empty`, `empty_as_varchar`.
- Writes with sheet name and sheet row limit.
- Temporal and boolean values are converted to Excel serial/format conventions.

QuackDB opportunity:

- Add docs/examples for remote “spreadsheet as table” workflows.
- Treat Excel export commands as command results and preserve normalized command metadata.

## Spatial/geospatial

The `spatial` extension is not autoloadable and must be installed/loaded explicitly:

```sql
INSTALL spatial;
LOAD spatial;
```

It enables geospatial processing and can introduce `GEOMETRY` values. QuackDB already notes geometry as a type fidelity gap.

QuackDB opportunity:

- Decide a public representation for geometry before claiming spatial support: WKB binary, WKT string, GeoJSON string, or extension-specific raw term.
- In the interim, document using SQL-side conversion functions such as returning WKT/GeoJSON text where appropriate.

## Database federation

DuckDB’s data-source docs list database integrations including PostgreSQL and MySQL, and the extension list includes SQLite-related support. These make DuckDB useful as a federated analytical query engine: QuackDB can remotely ask DuckDB to query files, lakehouses, and external databases in one SQL statement.

QuackDB opportunity:

- Provide examples for attaching external databases from a Quack session.
- Keep unsupported-feature errors explicit in Ecto. DuckDB SQL can do cross-source joins, but the current Ecto adapter should not pretend it supports joins until query generation is correct.

## DuckDB SQL features worth exposing in examples

These are not file formats, but they are powerful enough to shape QuackDB docs and tests:

- `PIVOT` / `UNPIVOT` for reshaping analytics results.
- `SUMMARIZE` for quick profiling/statistics.
- `SAMPLE` for approximate/exploratory workflows.
- `QUALIFY` for filtering window-function results.
- `FILTER` on aggregates.
- `GROUPING SETS`.
- `CREATE MACRO` for reusable SQL snippets.
- `CREATE TYPE` for enums and custom type workflows.
- `EXPORT DATABASE` / `IMPORT DATABASE`.
- `ATTACH` / `DETACH` for external catalogs and databases.
- `MERGE INTO` for analytical upserts where supported by table format.
- `COPY` for import/export across CSV, Parquet, JSON, and XLSX.
- `DESCRIBE`, `SHOW`, metadata table functions, and information schema for introspection.

## Suggested roadmap for QuackDB

1. Document remote analytical sources first:
   - Parquet over HTTPS/S3.
   - CSV with reject tables.
   - JSON extraction.
   - XLSX import/export.
   - Delta/Iceberg examples.
2. Add safe SQL builders for source scans:
   - `QuackDB.Source.parquet(path_or_paths, opts)`
   - `QuackDB.Source.csv(path_or_paths, opts)`
   - `QuackDB.Source.json(path_or_paths, opts)`
   - `QuackDB.Source.xlsx(path, opts)`
   These should only produce SQL fragments/literals; they should not hide DuckDB behavior or extension requirements.
3. Add secret-management guidance:
   - Prefer DuckDB `CREATE SECRET` with `credential_chain`.
   - Warn against logging SQL containing credentials.
   - Provide Phoenix/runtime config examples.
4. Expand type fidelity tests for advanced sources:
   - `JSON`, `VARIANT`, `UNION`, `GEOMETRY`, `TIME WITH TIME ZONE`, `BIGNUM`.
   - Lakehouse nested structs/lists/maps.
5. Add command-result tests for export/import/copy:
   - `COPY ... TO`
   - `EXPORT DATABASE`
   - `CHECKPOINT` on attached lakehouse tables where practical.
6. Make Ecto analytical, not minimal:
   - Raw SQL should expose the full DuckDB surface immediately.
   - Ecto should grow toward DuckDB-native analytical queries instead of staying limited to CRUD-shaped SQL.
   - Prioritize read/query features that map naturally to DuckDB: joins, fragments, windows, aggregates, `FILTER`, `PIVOT`/`UNPIVOT`, CTEs, source scans, and schema-less results.
   - Keep unsupported-feature errors explicit only where semantics are genuinely unclear or unimplemented.

## References reviewed

- DuckDB data sources overview.
- CSV import docs.
- JSON overview docs.
- Parquet overview docs.
- HTTP(S) and S3 API support docs.
- Lakehouse formats support matrix.
- Delta extension docs.
- Iceberg extension docs.
- Excel extension docs.
- `CREATE SECRET` statement docs.
- Spatial extension overview.

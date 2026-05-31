# DuckDB performance tuning notes for QuackDB

Sources reviewed:

- DuckDB configuration overview: <https://duckdb.org/docs/current/configuration/overview.html>
- DuckDB workload tuning guide: <https://duckdb.org/docs/current/guides/performance/how_to_tune_workloads.html>
- DuckDB indexing guide: <https://duckdb.org/docs/current/guides/performance/indexing.html>
- DuckDB INSERT guidance: <https://duckdb.org/docs/current/data/insert.html>
- DuckDB Appender guidance: <https://duckdb.org/docs/current/data/appender.html>
- DuckDB concurrency model: <https://duckdb.org/docs/current/connect/concurrency.html>
- Live DuckDB 1.5.3 `duckdb_settings()` inspection with the `quack` extension loaded.

## Settings worth exposing or sweeping

| Setting | Current DuckDB/Quack meaning | QuackDB implication |
| --- | --- | --- |
| `threads` / `worker_threads` | Total DuckDB execution threads. | Sweep from `1` to scheduler count. More threads can improve large scans/aggregates but can hurt many concurrent small requests by oversubscribing CPU. |
| `memory_limit` / `max_memory` | Maximum memory DuckDB may use before spilling or failing. | Important for large result-producing queries, joins, sorts, and imports. Stress tests should include constrained memory runs to find whether failures surface clearly through QuackDB. |
| `temp_directory` | Directory for spill files. | Set explicitly for production and stress runs so spills are observable and do not unexpectedly use the project directory. |
| `max_temp_directory_size` | Cap for data stored in `temp_directory`. | Useful for predictable failure testing under large sorts/joins. |
| `preserve_insertion_order` | Defaults to `true`; setting `false` lets DuckDB reorder unordered results and can lower memory use for large imports/exports. | QuackDB docs should recommend `ORDER BY` for deterministic client-facing order and consider `preserve_insertion_order = false` for memory-heavy analytical workloads. |
| `checkpoint_threshold` / `wal_autocheckpoint` | WAL size threshold that triggers checkpointing. | Mostly relevant for file-backed databases and sustained writes. Native append stress should include file-backed runs later. |
| `allocator_background_threads`, `allocator_flush_threshold`, `allocator_bulk_deallocation_flush_threshold` | Allocator cleanup behavior after large tasks. | Potentially useful if BEAM-side memory is stable but DuckDB server RSS remains high after large queries. |
| `quack_fetch_batch_chunks` | Quack extension setting: maximum DataChunks returned per fetch response. Live default in DuckDB 1.5.3 was `12`; QuackDB.Server currently defaults to `4`. | Primary Quack-specific tuning knob. Larger values should improve large-result throughput but increase per-response decode latency and client memory pressure. Sweep `1, 4, 12, 32, 64`. |

## Workload guidance that matters for QuackDB

### Bulk writes

DuckDB documents row-by-row `INSERT` loops as inefficient because each statement pays parsing and execution overhead. For QuackDB this maps to:

- Prefer `QuackDB.insert_rows/4`, `insert_columns/4`, `insert_stream/4`, or Ecto `insert_all(..., insert_method: :append)` for bulk writes.
- Keep Ecto SQL `insert_all` for moderate row counts or when conflict/returning semantics matter.
- Tune append batch size. Too small pays request/protocol overhead; too large increases client encoding memory and server append latency.
- Stress both row-oriented and column-oriented append; column-oriented appends should avoid part of the row-to-column reshaping cost for large batches.

### Large reads

DuckDB returns vectorized DataChunks; QuackDB turns them into row-friendly results by default.

- `QuackDB.query/4` materializes the whole result and is convenient but should not be the default for very large result sets.
- `QuackDB.rows/4`, `maps/4`, `column_batches/4`, and `columnar_batches/4` should be stress-tested as the preferred large-result APIs.
- `max_rows` and `quack_fetch_batch_chunks` together determine batch size and memory pressure. We need throughput and p95 latency data for both.

### Parallelism and row groups

DuckDB parallelizes work internally. The tuning guide calls out row groups as a parallelism boundary for file/table scans. For QuackDB:

- More DBConnection clients do not necessarily mean more DuckDB throughput if each query already uses all DuckDB threads.
- Concurrency testing should cross product `pool_size`/client concurrency with DuckDB `threads`.
- The likely sweet spot is different for small point queries, large scans, append-heavy jobs, and mixed workloads.

### Ordering and zonemaps

DuckDB automatically creates zonemaps. Ordered data improves pruning and compression.

- Stress data should include ordered and shuffled variants later.
- QuackDB examples should avoid implying indexes are required for typical analytical scans; ordered load plus predicates can matter more.
- ART indexes are useful for highly selective point lookups but add write overhead and should be tested separately from append throughput.

### Concurrency model

DuckDB supports concurrent readers and writers inside one process, with MVCC and optimistic concurrency control. Multiple processes can read a database in read-only mode, but write access is single-process oriented.

For QuackDB this means:

- A supervised DuckDB server process with multiple QuackDB client connections is the right model for mixed Elixir workloads.
- Concurrent write stress should expect conflict/serialization behavior from DuckDB, not unlimited writer scaling.
- QuackDB should make timeout and conflict failures clear rather than hiding them behind connection errors.

## Initial weak-point hypotheses

1. Large materialized results may spend more time and memory in protocol decode and row materialization than in DuckDB execution.
2. `quack_fetch_batch_chunks = 4` may be conservative for high-throughput local networks; larger fetch batches may improve `columnar_batches/4` throughput.
3. Many small queries may be dominated by HTTP/Mint transport, client-side SQL formatting, and `PrepareRequest` round trips.
4. Column-oriented append should beat row-oriented append once batches are large enough, but row-oriented `insert_stream/4` may be more memory-stable.
5. Concurrent analytical queries may oversubscribe CPU when `pool_size * threads` is too high.

## Stress-test plan

The initial harness in `bench/stress.exs` measures:

- small query latency and throughput
- concurrent aggregate latency
- full materialized row result throughput
- streamed row throughput
- columnar batch throughput
- native row append throughput
- native column append throughput

Recommended sweeps:

```sh
# Fast smoke run
QUACKDB_STRESS_ROWS=10000 QUACKDB_STRESS_QUERIES=50 mix run bench/stress.exs

# Fetch-batch sweep
for chunks in 1 4 12 32 64; do
  QUACKDB_STRESS_FETCH_BATCH_CHUNKS=$chunks \
  QUACKDB_STRESS_ROWS=250000 \
  mix run bench/stress.exs
done

# CPU/concurrency sweep
for threads in 1 2 4 8; do
  for concurrency in 1 2 4 8; do
    QUACKDB_STRESS_THREADS=$threads \
    QUACKDB_STRESS_CONCURRENCY=$concurrency \
    QUACKDB_STRESS_ROWS=250000 \
    mix run bench/stress.exs
  done
 done

# Append batch-size sweep
for batch in 100 1000 5000 20000; do
  QUACKDB_STRESS_BATCH_SIZE=$batch \
  QUACKDB_STRESS_SCENARIOS=append_rows,append_columns \
  QUACKDB_STRESS_ROWS=250000 \
  mix run bench/stress.exs
 done
```

The harness emits `METRIC scenario.key=value` lines so results can later be parsed into CSV or autoresearch-style logs.

## Next instrumentation to add after baseline

- Server RSS sampling via `QuackDB.Server.os_pid/1` and `ps` during each scenario.
- Separate DuckDB execution time from transport/decode time using `EXPLAIN ANALYZE` or profiling output for selected SQL.
- File-backed database runs to observe checkpoint/WAL behavior.
- Nested-heavy decode scenarios: LIST/STRUCT/MAP/JSON/null-heavy columns.
- A mixed workload scenario with reads and appends running simultaneously.

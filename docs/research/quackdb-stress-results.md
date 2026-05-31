# QuackDB stress results

## 2026-05-31 baseline

Command:

```sh
QUACKDB_STRESS_ROWS=100000 \
QUACKDB_STRESS_QUERIES=100 \
QUACKDB_STRESS_CONCURRENCY=4 \
QUACKDB_STRESS_BATCH_SIZE=5000 \
QUACKDB_STRESS_FETCH_BATCH_CHUNKS=4 \
mix run bench/stress.exs
```

Environment:

- Local supervised DuckDB Quack server started by `bench/stress.exs`.
- Server settings: `threads=10`, `quack_fetch_batch_chunks=4`.
- Database: in-memory.

| Scenario | Count | Elapsed ms | Rate/s | Notes |
| --- | ---: | ---: | ---: | --- |
| `small_query` | 100 | 11.54 | 8,663 | p50 357 µs, p95 641 µs, p99 927 µs. |
| `concurrent_aggregate` | 100 | 22.58 | 4,428 | p50 798 µs, p95 1,400 µs, p99 1,565 µs. |
| `materialized_result` | 100,000 | 1,347.92 | 74,188 | Materializing all rows is the slowest narrow-read path and increased BEAM memory by ~22 MB in this run. |
| `streamed_rows` | 100,000 | 911.37 | 109,726 | Faster than full materialization, but still row-shaped. |
| `columnar_batches` | 100,000 | 914.65 | 109,331 | Similar throughput to row streaming for this four-column scalar workload; memory delta was much smaller than materialization. |
| `append_rows` | 100,000 | 55.40 | 1,805,022 | Native append is much faster than result materialization. |
| `append_columns` | 100,000 | 45.84 | 2,181,406 | ~21% faster than row append for this scalar workload. |

## 2026-05-31 targeted sweeps

The harness now also records DuckDB server RSS by summing the MuonTrap wrapper process and its descendants. RSS values are useful for large deltas, but short scenarios can be noisy because DuckDB allocator behavior and OS accounting lag behind the query boundary.

### Fetch batch chunks

Command shape:

```sh
for chunks in 1 4 12 32 64; do
  QUACKDB_STRESS_ROWS=100000 \
  QUACKDB_STRESS_QUERIES=50 \
  QUACKDB_STRESS_CONCURRENCY=4 \
  QUACKDB_STRESS_FETCH_BATCH_CHUNKS=$chunks \
  QUACKDB_STRESS_SCENARIOS=materialized_result,streamed_rows,columnar_batches,wide_nested_materialized,wide_nested_columnar_batches \
  mix run bench/stress.exs
 done
```

| `quack_fetch_batch_chunks` | Materialized narrow rows/s | Streamed narrow rows/s | Columnar narrow rows/s | Materialized wide/nested rows/s | Columnar wide/nested rows/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 55,492 | **159,983** | **140,835** | 10,155 | **13,133** |
| 4 | 67,844 | 102,356 | 108,049 | **10,399** | 12,121 |
| 12 | **69,226** | 84,324 | 81,518 | 9,922 | 11,595 |
| 32 | 68,781 | 74,079 | 68,527 | 10,206 | 10,358 |
| 64 | 65,664 | 60,636 | 61,404 | 9,926 | 9,823 |

Findings:

- For streaming APIs, `quack_fetch_batch_chunks=1` was fastest in this local run. Larger Quack responses likely increase client decode/materialization latency more than they save round trips.
- Materialized narrow reads prefer `12`, but materialized reads are not the recommended large-result path.
- Wide/nested decode is an order of magnitude slower than narrow scalar decode. Columnar batches help wide/nested results by ~29% at `chunks=1`.
- QuackDB.Server's default of `4` is safer than `12` for streaming, but this run suggests testing a lower default or documenting `1` for latency-sensitive streaming.

### DuckDB threads × client concurrency

Command shape:

```sh
for threads in 1 2 4 8; do
  for concurrency in 1 2 4 8; do
    QUACKDB_STRESS_ROWS=50000 \
    QUACKDB_STRESS_QUERIES=100 \
    QUACKDB_STRESS_THREADS=$threads \
    QUACKDB_STRESS_CONCURRENCY=$concurrency \
    QUACKDB_STRESS_SCENARIOS=small_query,concurrent_aggregate \
    mix run bench/stress.exs
  done
 done
```

| Threads | Concurrency | Small query/s | Aggregate query/s |
| ---: | ---: | ---: | ---: |
| 1 | 1 | 5,470 | 2,400 |
| 1 | 2 | 6,663 | 3,486 |
| 1 | 4 | 11,519 | 5,732 |
| 1 | 8 | **12,700** | **7,070** |
| 2 | 1 | 4,700 | 1,550 |
| 2 | 2 | 7,400 | 2,438 |
| 2 | 4 | 7,059 | 3,285 |
| 2 | 8 | 10,600 | 6,932 |
| 4 | 1 | 3,259 | 1,242 |
| 4 | 2 | 5,672 | 2,607 |
| 4 | 4 | 5,614 | 3,905 |
| 4 | 8 | 11,783 | 5,850 |
| 8 | 1 | 4,390 | 1,866 |
| 8 | 2 | 6,398 | 2,457 |
| 8 | 4 | 8,093 | 4,554 |
| 8 | 8 | 10,695 | 5,328 |

Findings:

- These small and moderate aggregate workloads favored `threads=1` with higher client concurrency.
- More DuckDB threads hurt single-query latency and did not win the concurrent aggregate workload at this scale.
- This does not mean `threads=1` is generally best; larger scans, joins, Parquet reads, and file-backed workloads still need a separate sweep.
- QuackDB documentation should recommend tuning `threads` by workload instead of blindly using `System.schedulers_online()` for every server.

### Append batch size

Command shape:

```sh
for batch in 100 1000 5000 20000; do
  QUACKDB_STRESS_ROWS=100000 \
  QUACKDB_STRESS_BATCH_SIZE=$batch \
  QUACKDB_STRESS_SCENARIOS=append_rows,append_columns \
  mix run bench/stress.exs
 done
```

| Batch size | Row append rows/s | Column append rows/s |
| ---: | ---: | ---: |
| 100 | 300,568 | 366,631 |
| 1,000 | 1,231,330 | 1,299,191 |
| 5,000 | **1,521,630** | **1,712,124** |
| 20,000 | 1,266,256 | 1,647,582 |

Findings:

- Very small batches are dominated by request/protocol overhead.
- `5,000` was the best row and column append batch size in this run.
- `20,000` increased client memory pressure and reduced row append throughput; it remained close for column append but did not beat `5,000`.
- The current `insert_stream/4` default of `1,000` is conservative. A higher default around `5,000` may be worth considering after more payload-shape testing.

## Bugs and weak points surfaced

1. Large row materialization remains the clearest bottleneck. Streaming should be promoted in docs and examples for large result sets.
2. Wide/nested result decoding is much slower than narrow scalar decoding. This points at protocol vector decode and nested value materialization as optimization targets.
3. Larger `quack_fetch_batch_chunks` values can make streaming slower. This was counterintuitive and should be validated on larger row counts and remote networks before changing defaults.
4. `CASE WHEN id % 10 = 0 THEN NULL::DOUBLE ELSE amount END` in the wide/nested stress query triggered `expected a 64-bit float` during decode. This was fixed by skipping physical payload decoding for invalid fixed-width vector slots; DuckDB can store non-decodable sentinel bytes in null `DOUBLE` slots.
5. The benchmark still reports client-observed time only. We need server-side profiling (`EXPLAIN ANALYZE` or DuckDB profiling output) to split DuckDB execution from Quack transport/protocol/client materialization.

## Next actions

- Add a profiling mode to `bench/stress.exs` that runs `EXPLAIN ANALYZE` for read scenarios and stores the plan text next to client timings.
- Add larger analytical/file-backed sweeps before changing `threads` defaults.
- Add payload-shape sweeps for append defaults: narrow scalar, wide scalar, nested, strings, blobs, and null-heavy batches.
- Consider documenting `quack_fetch_batch_chunks=1` for local streaming workloads and keeping the default conservative until remote-network runs are available.

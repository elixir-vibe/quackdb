# QuackDB stress benchmark notes

These notes capture local benchmark results from `bench/stress.exs`. They are research data, not user-facing documentation or release notes.

## Harness

`bench/stress.exs` starts a local supervised DuckDB Quack server unless `QUACKDB_STRESS_URI` or `QUACKDB_TEST_URI` is provided. It creates an in-memory source table, runs selected scenarios, and prints parseable `METRIC scenario.key=value` lines.

Common options:

| Environment variable | Default | Meaning |
| --- | ---: | --- |
| `QUACKDB_STRESS_ROWS` | `100000` | Source rows and append rows. |
| `QUACKDB_STRESS_QUERIES` | `200` | Number of small/concurrent query operations. |
| `QUACKDB_STRESS_CONCURRENCY` | schedulers online | Client pool size and concurrent tasks. |
| `QUACKDB_STRESS_BATCH_SIZE` | `5000` | Append batch size. |
| `QUACKDB_STRESS_FETCH_ROWS` | `10000` | Stream fetch row limit. |
| `QUACKDB_STRESS_THREADS` | schedulers online | DuckDB `threads` setting for local server runs. |
| `QUACKDB_STRESS_FETCH_BATCH_CHUNKS` | `12` | DuckDB Quack `quack_fetch_batch_chunks` setting. |
| `QUACKDB_STRESS_SCENARIOS` | all | Comma-separated scenario names. |
| `QUACKDB_STRESS_PROFILE` | `false` | Also run `EXPLAIN ANALYZE` for read scenarios and write plans to `tmp/stress-profiles/`. |

Scenarios:

- `small_query`
- `concurrent_aggregate`
- `materialized_result`
- `streamed_rows`
- `columnar_batches`
- `wide_nested_materialized`
- `wide_nested_columnar_batches`
- `append_rows`
- `append_columns`

## Baseline run

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

- local supervised DuckDB Quack server
- in-memory database
- `threads=10`
- `quack_fetch_batch_chunks=4`

| Scenario | Count | Elapsed ms | Rate/s | Notes |
| --- | ---: | ---: | ---: | --- |
| `small_query` | 100 | 11.54 | 8,663 | p50 357 µs, p95 641 µs, p99 927 µs. |
| `concurrent_aggregate` | 100 | 22.58 | 4,428 | p50 798 µs, p95 1,400 µs, p99 1,565 µs. |
| `materialized_result` | 100,000 | 1,347.92 | 74,188 | Highest BEAM memory pressure among narrow read paths. |
| `streamed_rows` | 100,000 | 911.37 | 109,726 | Faster than full materialization, still row-shaped. |
| `columnar_batches` | 100,000 | 914.65 | 109,331 | Similar throughput before columnar-path optimizations. |
| `append_rows` | 100,000 | 55.40 | 1,805,022 | Native append is much faster than result materialization. |
| `append_columns` | 100,000 | 45.84 | 2,181,406 | Faster than row append for this scalar workload. |

## Targeted sweeps

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

- Local streaming workloads favored `quack_fetch_batch_chunks=1`.
- Larger fetch responses can increase client decode latency more than they save round trips.
- Materialized narrow reads favored `12`, but materialized reads are not the preferred large-result API.
- Keep QuackDB's default conservative until remote-network runs are available.

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

- This small-query workload favored `threads=1` with higher client concurrency.
- More DuckDB threads hurt single-query latency at this scale.
- This does not generalize to large scans, joins, Parquet reads, or file-backed workloads.

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
- `5,000` was best for this scalar append workload.
- Larger batches should be retested with wide, nested, string-heavy, blob-heavy, and null-heavy payloads before changing defaults.

## Profiling split

Command shape:

```sh
QUACKDB_STRESS_ROWS=50000 \
QUACKDB_STRESS_PROFILE=1 \
QUACKDB_STRESS_TIMEOUT=180000 \
QUACKDB_STRESS_SCENARIOS=materialized_result,streamed_rows,columnar_batches,wide_nested_materialized,wide_nested_columnar_batches \
mix run bench/stress.exs
```

`QUACKDB_STRESS_PROFILE=1` writes `EXPLAIN ANALYZE` plans to `tmp/stress-profiles/*.txt` and emits DuckDB's reported total time when parseable.

| Scenario | Rows | Client elapsed ms | DuckDB total ms | Client overhead ms | Rows/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| `materialized_result` | 50,000 | 801.82 | 2.50 | 799.32 | 62,358 |
| `streamed_rows` | 50,000 | 731.98 | 3.30 | 728.68 | 68,308 |
| `columnar_batches` | 50,000 | 704.67 | 1.60 | 703.07 | 70,956 |
| `wide_nested_materialized` | 50,000 | 5,688.66 | 10.50 | 5,678.16 | 8,789 |
| `wide_nested_columnar_batches` | 50,000 | 5,697.78 | 8.60 | 5,689.18 | 8,775 |

Finding: for these local read scenarios, DuckDB execution was not the bottleneck. Most time was in Quack transport, protocol decode, and result materialization.

## Decode/materialization optimization results

Profiling found two O(n²) client-side paths:

- `QuackDB.Protocol.DataChunk.rows/2` used indexed list access for each cell.
- `QuackDB.Protocol.Vector.list_values/4` sliced from the start of child-value lists for each list entry.

After replacing those with linear traversal/tuple-indexed extraction and adding a true columnar cursor path, 50,000-row results improved significantly.

| Scenario | Before elapsed ms | Current elapsed ms | Before rows/s | Current rows/s |
| --- | ---: | ---: | ---: | ---: |
| `materialized_result` | 801.82 | 43.83 | 62,358 | 1,140,667 |
| `streamed_rows` | 731.98 | 41.65 | 68,308 | 1,200,567 |
| `columnar_batches` | 704.67 | 36.41 | 70,956 | 1,373,211 |
| `wide_nested_materialized` | 5,688.66 | 239.21 | 8,789 | 209,025 |
| `wide_nested_columnar_batches` | 5,697.78 | 256.11 | 8,775 | 195,230 |

## Current conclusions

- Use streaming or columnar APIs for large result sets; avoid full materialization unless the result is small.
- Keep `quack_fetch_batch_chunks` conservative for now. Local streaming favored `1`, but remote and high-latency networks may behave differently.
- `threads` needs workload-specific tuning; small local queries do not benefit from using all scheduler cores as DuckDB threads.
- Append batch size around `5,000` is promising for scalar batches, but defaults should not change without wider payload-shape coverage.

## Open follow-ups

- File-backed runs to observe checkpoint/WAL behavior.
- Remote-network fetch-batch sweeps.
- Append sweeps for wide, nested, blob-heavy, string-heavy, and null-heavy payloads.
- Mixed read/write workloads.

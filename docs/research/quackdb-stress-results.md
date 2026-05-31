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
| `materialized_result` | 100,000 | 1,347.92 | 74,188 | Materializing all rows is the slowest large-read path and increased BEAM memory by ~22 MB in this run. |
| `streamed_rows` | 100,000 | 911.37 | 109,726 | Faster than full materialization, but still row-shaped. |
| `columnar_batches` | 100,000 | 914.65 | 109,331 | Similar throughput to row streaming for this four-column scalar workload; memory delta was much smaller than materialization. |
| `append_rows` | 100,000 | 55.40 | 1,805,022 | Native append is much faster than result materialization. |
| `append_columns` | 100,000 | 45.84 | 2,181,406 | ~21% faster than row append for this scalar workload. |

## Initial weak points

1. Large row materialization is the clearest early bottleneck: it was ~26% slower than streaming and showed the largest BEAM memory increase.
2. Columnar batches did not significantly beat row streaming on a narrow scalar result, so future tests should use wider and nested results where column orientation may matter more.
3. Native append is strong, but column append is already measurably faster than row append; batch-size sweeps should identify where the crossover starts.
4. The current stress harness measures client-observed time only. The next step is to separate DuckDB execution time from HTTP/protocol decode/materialization time.

## Next sweeps

- `quack_fetch_batch_chunks`: `1, 4, 12, 32, 64` on 250k+ rows.
- `threads × concurrency`: `threads=1,2,4,8` and `concurrency=1,2,4,8`.
- append `batch_size`: `100, 1000, 5000, 20000`.
- wide/nested reads: add `LIST`, `STRUCT`, `MAP`, JSON, BLOB, and null-heavy columns.
- file-backed writes: measure WAL/checkpoint behavior and `checkpoint_threshold` effects.

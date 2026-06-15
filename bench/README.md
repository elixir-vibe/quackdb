# Benchmarks

## Wide append

`wide_append.exs` reproduces Exograph's wide fragment staging append shape with synthetic data: blob hashes, a wide AST blob, `BIGINT[]` term vectors, `BIGINT[]` sub-hash vectors, metadata strings, and timestamps.

Example:

```bash
mix run bench/wide_append.exs \
  --rows 670000 \
  --chunk 10000 \
  --connections 4 \
  --output bench-results/wide-append-20260615/wide-670k-concurrent4.json
```

Key local result from 2026-06-15:

| rows | connections | request bytes | elapsed | append aggregate | encode | transport/server |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 670k | 1 | 721 MB | 12.4s | 11.4s | 5.2s | 5.9s |
| 670k | 4 | 721 MB | 7.8s | 28.9s | 7.6s | 21.0s |

The 4-connection aggregate result matches Exograph's observed staged append cost profile: concurrency improves wall time but inflates aggregate transport/server time. This suggests the remaining staging cost is largely DuckDB/Quack server contention under concurrent append requests rather than client decode or response materialization.

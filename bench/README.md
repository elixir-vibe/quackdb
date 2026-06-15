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

Key local matrix from 2026-06-15 (`670k` rows, ~`721 MB` request bytes):

| connections | chunk | batches | elapsed | append aggregate | encode | transport/server |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 5k | 134 | 14.39s | 13.52s | 4.31s | 8.94s |
| 1 | 10k | 67 | 12.66s | 11.66s | 5.72s | 5.67s |
| 1 | 20k | 34 | 14.51s | 13.38s | 5.27s | 7.82s |
| 1 | 40k | 17 | 14.45s | 13.10s | 7.31s | 5.41s |
| 2 | 10k | 68 | 9.68s | 18.12s | 6.10s | 11.70s |
| 2 | 40k | 18 | 9.69s | 17.55s | 7.11s | 10.06s |
| 3 | 20k | 36 | 7.47s | 20.78s | 7.31s | 13.06s |
| 3 | 40k | 18 | 6.65s | 16.78s | 6.56s | 9.78s |
| 3 | 80k | 9 | 6.44s | 14.22s | 8.24s | 5.50s |
| 4 | 10k | 68 | 7.56s | 27.91s | 7.68s | 19.83s |
| 4 | 20k | 36 | 7.08s | 25.60s | 8.03s | 17.04s |
| 4 | 40k | 20 | 5.33s | 18.87s | 7.02s | 11.34s |
| 4 | 80k | 12 | 5.38s | 16.52s | 9.65s | 6.37s |

The matrix shows two useful effects: concurrency improves wall time but can inflate aggregate transport/server time, and larger chunks reduce per-request overhead in this isolated benchmark. The best synthetic wall time was `4` connections with `40k`-row chunks (`5.33s`). Exograph previously regressed at `20k` fragment-stage chunks, so this benchmark should guide but not replace a full Exograph validation before changing production chunking.

# Public API audit for 0.4.0

This audit tracks public API added after `0.3.0` so names can be reviewed before the next release.

## Ecto analytical helpers

`QuackDB.Ecto.Analytics` added or expanded helpers for analytical DuckDB expressions:

- Query profiling: `summarize/2,3,4` and `summarize!/2,3,4`.
- Conditional expressions: `QuackDB.Ecto.Conditionals.case_when/1`.
- Date/time: atom-aware `date_part/2`, `date_trunc/2`, `time_bucket/2,3` origins and offsets.
- JSON: `json_extract/2`, `json_extract_string/2`, `json_exists/2`, `json_contains/2`, plus Ecto access lowering.
- Aggregates: `list/1,2`, `string_agg/2,3`, `arg_max/2,3`, `arg_min/2,3`.
- Statistical/analytical helpers: `median/1`, `quantile_cont/2`, `quantile_disc/2`, `corr/2`, `stddev/1`, `variance/1`, `stddev_pop/1`, `var_pop/1`, `var_samp/1`, `covar_pop/2`, `covar_samp/2`, `regr_slope/2`, `regr_intercept/2`, `regr_count/2`, `regr_r2/2`, `regr_sxx/2`, `regr_sxy/2`, `regr_syy/2`, `skewness/1`, `kurtosis/1`, `kurtosis_pop/1`, `sem/1`, `entropy/1`, `mad/1`.
- Numeric precision/weighted helpers: `favg/1`, `fsum/1`, `product/1`, `weighted_avg/2`, `geometric_mean/1`.
- Approximate helpers: `approx_count_distinct/1`, `approx_quantile/2`, `approx_top_k/2`, `reservoir_quantile/2,3`.
- Boolean/bit helpers: `bool_and/1`, `bool_or/1`, `band/1`, `bor/1`, `bxor/1`, `bitstring_agg/1,3`.
- Histograms: `histogram/1`, `histogram_exact/2`, `equi_width_bins/3,4`.

Naming decisions to keep before `0.4.0`:

- Keep `band/1`, `bor/1`, and `bxor/1` for aggregate bitwise operations to match Elixir `Bitwise` naming rather than raw DuckDB `bit_and`, `bit_or`, and `bit_xor`.
- Keep `list/1,2` as the DuckDB-native aggregate name. Do not reintroduce `duckdb_list/1`.
- Keep conditional aggregates expressed through Ecto `filter/2`; do not add `count_if`/`countif` helpers.

## Ecto text, regex, spatial, and predicates

- `QuackDB.Ecto.Regex` exposes DuckDB `regexp_*` helpers and accepts compatible literal `~r` patterns.
- `QuackDB.Ecto.Text` exposes common string predicates and splitting helpers: `contains/2`, `contains_text/2`, `starts_with/2`, `ends_with/2`, `prefix/2`, `suffix/2`, `split_part/3`, `string_split/2`, and `string_split_regex/2,3`.
- `QuackDB.Ecto.Spatial.st_contains/2` is an explicit spatial escape hatch for shared `contains/2` use.
- The hidden predicates module is imported by `use QuackDB.Ecto` only to dispatch shared `contains/2`.

Open naming review before `0.4.0`:

- Accepted: `contains_text/2` is the explicit text escape hatch for ambiguous shared `contains/2` calls.
- Accepted: `st_contains/2` remains as an explicit spatial escape hatch alongside direct spatial imports.
- Accepted: ambiguous shared `contains/2` calls raise instead of defaulting to spatial.

## Window frames

`QuackDB.Ecto.WindowFrames` provides `rows_between/2`, `range_between/2`, and `groups_between/2`. They expand to `fragment(...)` and are intended for Ecto releases that include macro-expanded window frame support. Until QuackDB depends on such a release, examples should continue to show literal frame fragments.

## Direct SQL, sources, and append APIs

- `QuackDB.Analytics.summarize/1` renders direct DuckDB `SUMMARIZE` SQL for table names and raw query tuples.
- Source helpers added `QuackDB.Source.sample/2` and `QuackDB.Source.histogram_values/3`.
- Append helpers added `QuackDB.insert_stream/4`, `insert_stream!/4`, `insert_table/4`, and `insert_table!/4`.

## Maintainer tooling

- The `quackdb.functions.snapshot` Mix task writes a checked-in DuckDB function catalog snapshot under `priv/duckdb_functions/current.exs`.
- The snapshot stores normalized QuackDB type specs for overload auditing, but package compilation must not depend on a live DuckDB server.

## Pre-release checks

Before tagging `0.4.0`:

1. Re-read this file and decide whether open naming review items should change.
2. Run `mix ci`.
3. Run the full gated integration suite against DuckDB Quack.
4. Run `mix docs`.
5. Run `mix hex.build --unpack` and inspect package contents.

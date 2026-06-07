# Public API audit

This audit tracks public API changes and records accepted naming decisions before release cuts. No open naming decisions remain for the current release candidate.

## 0.5.2 API additions after 0.5.1

New public surfaces since `0.5.1`:

- Storage observability: `QuackDB.Storage.info/3`, `info!/3`, `compression/3`, `compression!/3`, `database_size/2`, `database_size!/2`, `checkpoint/2`, `checkpoint!/2`, `force_checkpoint/2`, `force_checkpoint!/2`, and storage segment/database-size/compression summary structs.
- Catalog metadata: `QuackDB.Meta.tables/2`, `tables!/2`, `databases/2`, `databases!/2`, `table_info/3`, `table_info!/3`, and table/database/column metadata structs.

Accepted naming decisions for 0.5.2 changes:

- Use `QuackDB.Storage.info!/2` rather than repeating storage in `storage_info!/2`.
- Keep storage observability outside `QuackDB.Ecto` because the same API accepts raw connections and Ecto repos.
- Use `compression!/2` for grouped per-table compression summaries instead of a longer `compression_summary!/2` name.
- Keep logical catalog helpers in `QuackDB.Meta` and physical storage/compression helpers in `QuackDB.Storage`.

## 0.5.1 API additions after 0.5.0

New public surfaces since `0.5.0`:

- DDL options: `QuackDB.DDL.create_table/2,3` accepts `or_replace: true` and `QuackDB.DDL.create_table(name, schema, opts)` can create a differently named table from an Ecto schema.
- Query profiling: `QuackDB.Profile.analyze/4`, `analyze!/4`, `explain/4`, `explain!/4`, `flatten/1`, `slowest/2`, `report/2`, and decoded profile/operator structs.
- SQL explain formats: `QuackDB.SQL.explain/2` accepts `format: :text | :json | :html | :graphviz | :mermaid`.

Accepted naming decisions for 0.5.1 changes:

- Keep DDL replacement and schema-copy staging as options/overloads on `create_table` rather than adding `replace_table_as/3` or `create_table_like/3`.
- Keep query profiling in `QuackDB.Profile` and reserve telemetry for client-side query/fetch/append timings.
- Decode DuckDB profile JSON into structs, while keeping open-ended `extra_info` keys as DuckDB returns them.

## 0.5.0 API additions after 0.4.2

Accepted naming decisions for 0.5.0 changes:

- Keep append opt-in explicit with `insert_method: :append`; do not add `insert_method: :auto`.
- Keep temporary append/returning internals private; do not add a public `append_insert_all` helper.
- Keep the LIST lambda AST translator hidden. LIST lambda macros are public; the translator is an implementation detail.
- Render DuckDB's Python-style lambda syntax (`lambda x : ...`) instead of deprecated arrow syntax.
- Keep LIST/MAP/STRUCT natural names in focused modules, but use explicit aliases such as `contains_list/2`, `intersect_list/2`, `contains_map/2`, `map_extract_value/2`, `contains_struct/2`, and `struct_extract/2` for broad `use QuackDB.Ecto` imports where names would conflict.
- Keep broad `contains/2` dispatch limited to obvious text/spatial cases until LIST/MAP/STRUCT expression typing is reliable enough to dispatch without surprises.
- Keep PIVOT, UNPIVOT, and GROUPING helpers as `QuackDB.SQL` builders rather than Ecto query DSL extensions.


## Ecto analytical helpers

`QuackDB.Ecto.Analytics` added or expanded helpers for analytical DuckDB expressions:

- Data profiling: `summarize/2,3,4` and `summarize!/2,3,4`.
- Query profiling: `QuackDB.Profile.analyze/4`, `analyze!/4`, `explain/4`, `explain!/4`, `flatten/1`, `slowest/2`, `report/2`, and decoded profile/operator structs.
- Conditional expressions: `QuackDB.Ecto.Conditionals.case_when/1`.
- Date/time: atom-aware `date_part/2`, `date_trunc/2`, `time_bucket/2,3` origins and offsets.
- JSON: `json_extract/2`, `json_extract_string/2`, `json_exists/2`, `json_contains/2`, plus Ecto access lowering.
- Aggregates: `list/1,2`, `string_agg/2,3`, `arg_max/2,3`, `arg_min/2,3`.
- Statistical/analytical helpers: `median/1`, `quantile_cont/2`, `quantile_disc/2`, `corr/2`, `stddev/1`, `variance/1`, `stddev_pop/1`, `var_pop/1`, `var_samp/1`, `covar_pop/2`, `covar_samp/2`, `regr_slope/2`, `regr_intercept/2`, `regr_count/2`, `regr_r2/2`, `regr_sxx/2`, `regr_sxy/2`, `regr_syy/2`, `skewness/1`, `kurtosis/1`, `kurtosis_pop/1`, `sem/1`, `entropy/1`, `mad/1`.
- Numeric precision/weighted helpers: `favg/1`, `fsum/1`, `product/1`, `weighted_avg/2`, `geometric_mean/1`.
- Approximate helpers: `approx_count_distinct/1`, `approx_quantile/2`, `approx_top_k/2`, `reservoir_quantile/2,3`.
- Boolean/bit helpers: `bool_and/1`, `bool_or/1`, `band/1`, `bor/1`, `bxor/1`, `bitstring_agg/1,3`.
- Histograms: `histogram/1`, `histogram_exact/2`, `equi_width_bins/3,4`.

Accepted naming decisions before `0.4.0`:

- Keep `band/1`, `bor/1`, and `bxor/1` for aggregate bitwise operations to match Elixir `Bitwise` naming rather than raw DuckDB `bit_and`, `bit_or`, and `bit_xor`.
- Keep `list/1,2` as the DuckDB-native aggregate name. Do not reintroduce `duckdb_list/1`.
- Keep conditional aggregates expressed through Ecto `filter/2`; do not add `count_if`/`countif` helpers.

## Ecto text, regex, spatial, and predicates

- `QuackDB.Ecto.Regex` exposes DuckDB `regexp_*` helpers and accepts compatible literal `~r` patterns.
- `QuackDB.Ecto.Text` exposes common string predicates and splitting helpers: `contains/2`, `contains_text/2`, `starts_with/2`, `ends_with/2`, `prefix/2`, `suffix/2`, `split_part/3`, `string_split/2`, and `string_split_regex/2,3`.
- `QuackDB.Ecto.Spatial.st_contains/2` is an explicit spatial escape hatch for shared `contains/2` use.
- The hidden predicates module is imported by `use QuackDB.Ecto` only to dispatch shared `contains/2`.

Accepted naming decisions before `0.4.0`:

- Keep `contains_text/2` as the explicit text escape hatch for ambiguous shared `contains/2` calls.
- Keep `st_contains/2` as the explicit spatial escape hatch alongside direct spatial imports.
- Keep ambiguous shared `contains/2` calls raising instead of defaulting to spatial.
- Keep the predicates module hidden; `contains/2` dispatch is an implementation detail of `use QuackDB.Ecto`.

## Window frames

`QuackDB.Ecto.WindowFrames` provides `rows_between/2`, `range_between/2`, and `groups_between/2`. They expand to `fragment(...)` and are intended for Ecto releases that include macro-expanded window frame support. Until QuackDB depends on such a release, examples should continue to show literal frame fragments.

Accepted naming decisions before `0.4.0`:

- Keep the module name `QuackDB.Ecto.WindowFrames`.
- Keep tuple bounds such as `{:preceding, 6}` and `{:following, 1}` plus atoms `:current_row`, `:unbounded_preceding`, and `:unbounded_following`. This keeps bounds compile-time data and avoids extra helper macros for each bound.

## Direct SQL, sources, and append APIs

- `QuackDB.Analytics.summarize/1` renders direct DuckDB `SUMMARIZE` SQL for table names and raw query tuples.
- Source helpers added `QuackDB.Source.sample/2` and `QuackDB.Source.histogram_values/3`.
- Append helpers added `QuackDB.insert_stream/4`, `insert_stream!/4`, `insert_table/4`, and `insert_table!/4`.
- Explicit `{:map, key_type, value_type}` append columns accept ordinary Elixir maps. Plain Elixir maps without an explicit MAP column spec continue to infer as DuckDB `STRUCT` values.

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

# Contributing

Thanks for helping improve QuackDB. QuackDB is an experimental remote DuckDB Quack protocol client, so protocol correctness and clear unsupported-feature errors matter more than broad but lossy behavior.

## Local checks

Run the standard local gate before opening a PR or preparing release-readiness changes:

```sh
mix ci
rm -rf doc && mix docs
```

## Real DuckDB Quack integration

Changes that affect protocol decoding/encoding, DBConnection behavior, Ecto SQL semantics, local server supervision, DuckDB helper SQL, or example workflows should also run against a real DuckDB Quack server.

Start or reuse a server:

```sh
duckdb -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

Then run:

```sh
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

## DuckDB function snapshots

QuackDB keeps a maintainer-generated DuckDB function catalog snapshot under `priv/duckdb_functions/current.exs`. Use it to audit curated Ecto analytical helpers against DuckDB runtime metadata without making normal package compilation depend on a live DuckDB server.

Regenerate it with a running Quack server:

```sh
QUACKDB_URI='http://[::1]:9494' \
QUACKDB_TOKEN=super_secret \
mix quackdb.functions.snapshot
```

The task records the normalized scalar/aggregate/macro function catalog plus post-processed helper candidates. Review snapshot diffs before committing; do not expose every candidate automatically.

## Example smoke checks

Run examples from outside the Mix project so `Mix.install/2` can load the local package:

```sh
cd /tmp
MIX_INSTALL_DIR=/tmp/quackdb-example-query elixir /path/to/quackdb/examples/query_observability.exs
MIX_INSTALL_DIR=/tmp/quackdb-example-dataframe elixir /path/to/quackdb/examples/dataframe_analytics.exs
MIX_INSTALL_DIR=/tmp/quackdb-example-fts elixir /path/to/quackdb/examples/full_text_search.exs
SMOKE=1 ROWS=10 BATCH_SIZE=5 MIX_INSTALL_DIR=/tmp/quackdb-example-append \
  elixir /path/to/quackdb/examples/append_benchmark.exs

cd /path/to/quackdb/examples/spatial_wms
mix deps.get
mix compile --warnings-as-errors
```

## Package audit

Before release-readiness changes, inspect the unpacked Hex package:

```sh
rm -rf quackdb-*.tar quackdb-*/
mix hex.build --unpack
find quackdb-* -type f | sort

if find quackdb-* \
  \( -path '*/examples/*' \
     -o -path '*docs/research*' \
     -o -path '*docs/testing*' \
     -o -path '*deps*' \
     -o -path '*_build*' \) -print | grep .; then
  echo "unexpected files in package" >&2
  exit 1
fi
```

Expected package contents are intentionally limited to the public package surface:

- `lib/`
- `guides/`
- `docs/protocol/`
- `docs/ecto-analytical-coverage.md`
- `README.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `.formatter.exs`
- `mix.exs`

The package should not include:

- `examples/`
- `docs/research/`
- `docs/testing/`
- `test/`
- `deps/`
- `_build/`
- local `tmp/` artifacts

## Optional dependency smoke

QuackDB has optional integrations for Ecto, Explorer, Geo, Table, and FSST. Optional dependency-backed modules should not emit compile warnings when optional dependencies are absent.

A minimal smoke project can verify this:

```sh
cd /tmp
rm -rf quackdb_minimal_smoke
mix new quackdb_minimal_smoke --sup
cd quackdb_minimal_smoke
```

Set `deps/0` in `mix.exs` to:

```elixir
defp deps do
  [
    {:quackdb, path: "/path/to/quackdb"}
  ]
end
```

Then compile with warnings as errors:

```sh
MIX_HOME=/tmp/quackdb-minimal-mix \
MIX_BUILD_PATH=/tmp/quackdb-minimal-build \
mix deps.get

MIX_HOME=/tmp/quackdb-minimal-mix \
MIX_BUILD_PATH=/tmp/quackdb-minimal-build \
mix compile --warnings-as-errors
```

## Release policy

Do not publish, tag, or create GitHub releases unless explicitly requested. Before a release candidate, review `CHANGELOG.md`, `README.md`, guides, package contents, and example smoke output.

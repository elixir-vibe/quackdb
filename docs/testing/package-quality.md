# Package quality checklist

Run this checklist before preparing a QuackDB release or asking reviewers to inspect release-readiness changes. For the full release-candidate workflow, see `docs/testing/release-dry-run.md`.

## Local checks

```sh
mix ci
rm -rf doc && mix docs
```

## Real DuckDB Quack integration

Start or reuse a DuckDB Quack server, then run:

```sh
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

A local server can be started manually with:

```sh
duckdb -interactive -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='super_secret');"
```

## Example smoke checks

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

## Hex package audit

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

Expected package contents:

- `lib/`
- `guides/`
- `docs/protocol/`
- `docs/ecto-analytical-coverage.md`
- `README.md`
- `CHANGELOG.md`
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

Use an explicit `package[:files]` list in `mix.exs` to keep these boundaries stable.

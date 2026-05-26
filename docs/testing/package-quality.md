# Package quality checklist

Run this checklist before preparing a QuackDB release or asking reviewers to inspect release-readiness changes.

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

## Hex package audit

```sh
rm -rf quackdb-*.tar quackdb-*/
mix hex.build --unpack
find quackdb-* -type f | sort
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

# Release dry run

Use this checklist to prepare a QuackDB release candidate for review. Do not publish, tag, or create a GitHub release unless explicitly requested.

## Full validation

```sh
mix ci
rm -rf doc && mix docs
QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=super_secret \
mix test --include integration
```

## Package audit

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

Expected excluded paths are documented in `docs/testing/package-quality.md`.

## Optional dependency smoke

Compile a minimal project that depends only on QuackDB, without optional Ecto, Explorer, Geo, Table, or FSST dependencies listed directly:

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

## Example smoke checks

Run examples from outside the Mix project so `Mix.install/2` resolves the local package:

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

## Final review

- Read `CHANGELOG.md` for end-user clarity.
- Check `README.md` and guides for stale API names and local links to files excluded from the Hex package.
- Confirm the package version and release notes match the intended release.
- Leave the repository clean after removing unpacked package directories.

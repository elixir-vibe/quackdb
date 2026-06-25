# Managed DuckDB binary

QuackDB can download and cache DuckDB's official CLI binary for local `QuackDB.Server` usage. This is opt-in: dependency compilation never downloads DuckDB.

## Local server

```elixir
children =
  QuackDB.Server.child_specs(
    server: [name: MyApp.DuckDB, duckdb: :managed],
    client: [name: MyApp.QuackDB]
  )
```

`QuackDB.Server` installs and loads the `quack` extension by default before serving. Set `install_quack?: false` only when the extension is already installed and startup must not attempt installation.

Omit `duckdb: :managed` to use `duckdb` from `PATH`, or pass a path explicitly:

```elixir
{QuackDB.Server, duckdb: "/usr/local/bin/duckdb"}
```

You can also force a path globally:

```sh
export QUACKDB_BINARY_PATH=/usr/local/bin/duckdb
```

## Explicit install

```sh
mix quackdb.install
mix quackdb.install --print-path
```

Managed binaries are cached under the user's cache directory. Override it with:

```sh
export QUACKDB_BINARY_CACHE_DIR=/opt/quackdb/duckdb
mix quackdb.install
```

or:

```sh
mix quackdb.install --cache-dir /opt/quackdb/duckdb
```

## Version and checksum policy

`QuackDB.Binary.default_version/0` is the DuckDB CLI version pinned by the current QuackDB release. QuackDB ships SHA256 checksums for that version and the supported targets returned by `QuackDB.Binary.known_targets/0`.

Other DuckDB versions must pass an explicit checksum:

```sh
mix quackdb.install --version 1.5.4 --sha256 SHA256_HEX
```

```elixir
QuackDB.Binary.install(version: "1.5.4", sha256: "SHA256_HEX")
```

## Target prefetching

The install task can prefetch a supported target without validating that binary on the current host:

```sh
mix quackdb.install --target linux-amd64 --cache-dir priv/quackdb-binaries
```

This is useful for CI cache priming or container image build steps. Runtime `duckdb: :managed` still chooses the current OS/architecture automatically.

Supported managed-download targets for the pinned version are:

- `linux-amd64`
- `linux-arm64`
- `osx-amd64`
- `osx-arm64`

Windows managed downloads are not supported yet. Use `QUACKDB_BINARY_PATH` or pass `duckdb: "C:/path/to/duckdb.exe"` on Windows until zip extraction and checksum coverage are added.

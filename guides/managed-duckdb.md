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

`QuackDB.Server` runs DuckDB's idempotent `INSTALL quack` and then `LOAD quack` by default before serving. It writes generated boot SQL to an Elixir-managed temporary init file by default, so generated local server tokens are not embedded in process arguments. Set `install_quack?: false` only for locked-down environments that preinstall extensions and forbid startup-time extension installation.

Omit `duckdb: :managed` to use `duckdb` from `PATH`, or pass a path explicitly:

```elixir
{QuackDB.Server, duckdb: "/usr/local/bin/duckdb"}
```

You can also force a path globally:

```sh
export QUACKDB_BINARY_PATH=/usr/local/bin/duckdb
```

## Pairing with an Ecto Repo

Pass a standard `{module, options}` child tuple to `QuackDB.Server.child_specs/1` to pair the server with a Repo instead of a direct client pool:

```elixir
alias QuackDB.Server

children =
  Server.child_specs(
    server: [name: MyApp.DuckDB, duckdb: :managed, database: "tasks.duckdb"],
    client: {MyApp.Repo, pool_size: 2}
  )
Supervisor.start_link(children, strategy: :rest_for_one)
```

`MyApp.Repo` must use `Ecto.Adapters.QuackDB`. Both specs retain the same URI/token across restarts. Server options take precedence over client options; omitted credentials are generated. The server starts first; `:rest_for_one` also restarts the Repo if its server crashes and invalidates sessions. The original `client: [name: MyApp.QuackDB]` form remains shorthand for a direct DBConnection pool. Custom client modules must accept `:uri` and `:token` options; their `child_spec/1` controls the client child specification.

## Startup diagnostics

Readiness requires the CLI's matching `quack_serve` result row or a successful protocol probe, not merely a log line mentioning the endpoint. The default init file explicitly selects CSV output. HTTP probes run in a cancellable task: a stalled endpoint cannot hide daemon exits or extend the startup deadline. Daemon exit before readiness fails promptly, including exit status where available.

Startup errors use these `QuackDB.Error.code` values:

- `:database_locked`: a recognized DuckDB file-lock conflict. Unknown wording remains a generic startup failure.
- `:server_start_failed`: the daemon exited before becoming ready.
- `:server_start_timeout`: the readiness deadline expired.

Metadata includes `:database`, `:uri`, `:last_error`, `:output_tail` (at most 8 KiB), and `:exit_reason` for daemon exits. The retained tail redacts the server token, replaces invalid UTF-8, and truncates on a character boundary so it remains safe to encode as JSON text. Custom boot output can contain other sensitive data. MuonTrap capture is newline-delimited and best-effort; disabling stderr forwarding can hide errors. Explicit logger callbacks and `log_output` still receive original output, which can contain the token. An invalid executable can fail before the daemon starts and retains its underlying launch error.

`Server.os_pid/1` and `Server.info/1` expose the **MuonTrap wrapper PID**, not DuckDB's child PID or the owner of a conflicting database lock. They cannot discover another application's database owner.

## Concurrency, shutdown, and copying files

Multiple clients can connect to one Quack server concurrently. Do not start a separate owner of the same native database file for each command while a writer is running. DuckDB permits one read/write process **or** multiple read-only processes with no writer—not independent readers alongside a writer. See [DuckDB concurrency](https://duckdb.org/docs/current/connect/concurrency.html).

Server shutdown signals MuonTrap and does not automatically checkpoint. A remaining `.wal` file is normal recovery state and may contain committed data absent from the main file. **Do not delete it or copy only the main file after an unclean exit.** Reopen the original database with its WAL to recover it.

For a single-file copy:

1. Prevent new writes from **all** clients and finish active transactions.
2. Run `QuackDB.Storage.checkpoint!/1` through the still-running Repo or direct connection; handle failure before proceeding.
3. Stop clients, then terminate the server child through its supervisor. `GenServer.stop/1` alone will restart a permanent supervised child.
4. Verify the OS process has exited and released the file, then copy the checkpointed database. The Server process returning from shutdown is not itself OS-exit confirmation.

Keep writers quiescent throughout. `force_checkpoint!/1` can wait for active transactions; it is not a write-draining or shutdown API. Neither helper can guarantee a single-file artifact after a crash, SIGKILL, or power loss. Prefer a tested backup workflow when other clients cannot be excluded. `recovery_mode: :no_wal_writes` is only for rebuildable artifacts, not a durability workaround.

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
mix quackdb.install --version 1.5.5 --sha256 SHA256_HEX
```

```elixir
QuackDB.Binary.install(version: "1.5.5", sha256: "SHA256_HEX")
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

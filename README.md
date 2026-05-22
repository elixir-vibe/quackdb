# QuackDB

Remote DuckDB Quack protocol client for Elixir.

`quackdb` is intended to become a protocol-native, DBConnection-ready client for DuckDB's experimental Quack remote protocol. The first milestone is a correct low-level codec and client session layer; Ecto support will be built on top once the driver semantics are solid.

## Status

Research and scaffolding phase. See [`docs/research.md`](docs/research.md) for the protocol notes, Ecto integration plan, comparable Elixir backends, and implementation roadmap.

## API

```elixir
{:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", token: "secret")

{:ok, result} = QuackDB.query(conn, "SELECT 1 AS n")
#=> %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}

{:ok, query, result} = QuackDB.prepare_execute(conn, "SELECT 1 AS n")

DBConnection.transaction(conn, fn tx ->
  QuackDB.stream(tx, "SELECT * FROM large_table")
  |> Enum.each(&IO.inspect/1)
end)
```

The public API is backed by `DBConnection`; the low-level protocol codec remains independent from connection pooling and future Ecto integration.

Future Ecto usage:

```elixir
defmodule MyApp.AnalyticsRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

## Development

```sh
mix deps.get
mix ci
```

Integration tests are skipped by default. To run them against a Quack server:

```sh
tail -f /dev/null | duckdb -init /dev/null \
  -cmd "LOAD quack; CALL quack_serve('quack:localhost', token='secret');"

QUACKDB_TEST_URI='http://[::1]:9494' \
QUACKDB_TEST_TOKEN=secret \
mix test --include integration
```

`quack:localhost` may bind on IPv6 localhost, so the example URI uses `[::1]`.

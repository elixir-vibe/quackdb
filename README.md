# QuackDB

Remote DuckDB Quack protocol client for Elixir.

`quackdb` is intended to become a protocol-native, DBConnection-ready client for DuckDB's experimental Quack remote protocol. The first milestone is a correct low-level codec and client session layer; Ecto support will be built on top once the driver semantics are solid.

## Status

Research and scaffolding phase. See [`docs/research.md`](docs/research.md) for the protocol notes, Ecto integration plan, comparable Elixir backends, and implementation roadmap.

## Intended API

```elixir
{:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", token: "secret")

{:ok, result} = QuackDB.query(conn, "SELECT 1 AS n")
#=> %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}
```

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

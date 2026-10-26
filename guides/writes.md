# Writes

QuackDB writes rows, columns, Explorer dataframes, `Table.Reader` data, and streams as binary DuckDB vectors instead of generating `INSERT VALUES` SQL, from a connection or a QuackDB-backed Ecto Repo.

Each write is one `INSERT INTO table (columns) SELECT * FROM scan_data_from_quack_client(...)` statement. The server prepares it, the client streams numbered batches of vectors into it, and the statement's own result comes back like any query result. Because it is an ordinary `INSERT`, column defaults and sequences apply to omitted columns, `ON CONFLICT` and `RETURNING` work, the write joins an open transaction, and DuckDB casts the vectors to the column types.

## Rows and columns

```elixir
QuackDB.insert_rows!(conn, "events", [
  [id: 1, name: "duck", tags: ["bird", "wetland"]],
  [id: 2, name: "goose", tags: ["bird", "loud"]]
])

QuackDB.insert_columns!(conn, "measurements", [
  id: [1, 2, 3],
  temperature: [12.5, 13.0, 12.8]
])
```

`ON CONFLICT` and `RETURNING` go on the same call:

```elixir
QuackDB.insert_rows!(conn, "events", rows,
  on_conflict: {:nothing, [:id]},
  returning: [:id, :inserted_at]
)
```

Explicit MAP columns accept ordinary Elixir maps while plain map inference stays STRUCT-shaped:

```elixir
QuackDB.insert_rows!(conn, "events", [[id: 1, labels: %{env: "prod", region: "eu"}]],
  columns: [id: :integer, labels: {:map, :varchar, :varchar}]
)
```

VARIANT columns accept any JSON-shaped Elixir value. Declare them as `:variant` so each value keeps its own shape; QuackDB sends the values as JSON text and DuckDB casts them on insert. `:json` does the same for JSON columns but passes strings through as JSON text:

```elixir
QuackDB.insert_rows!(conn, "events", [[payload: %{kind: "duck"}], [payload: [1, 2]], [payload: "quack"]],
  columns: [payload: :variant]
)
```

## Dataframes

When Explorer is installed, dataframes can be appended directly:

```elixir
alias Explorer.DataFrame
alias QuackDB.Explorer, as: QuackExplorer

frame = DataFrame.new(id: [1, 2], name: ["duck", "goose"])
QuackExplorer.insert_dataframe!(conn, "events", frame)
```

## Streams and Table.Reader data

Enumerable rows can be streamed into native append batches. The connection can be a QuackDB connection or a QuackDB-backed Ecto repo:

```elixir
File.stream!("events.ndjson")
|> Stream.map(&JSON.decode!/1)
|> QuackDB.insert_stream!(MyApp.AnalyticsRepo, "events", chunk_every: 10_000)
```

Any `Table.Reader`-compatible data can be appended through the same column append path:

```elixir
QuackDB.insert_table!(conn, "events", %{id: [1, 2], name: ["duck", "goose"]})
```

## Types, batching, and Ecto

Appends support explicit types, batching, scalar DuckDB values, and nested `LIST`, `STRUCT`, `ARRAY`, `MAP`, and `VARIANT` values. `:batch_size` sets the rows per request; QuackDB splits each request into vectors of at most 2048 rows. Ecto `insert_all(..., insert_method: :append)` uses schema types for nullable batches and supports `on_conflict: :nothing` and `RETURNING` in the same single statement. Direct append inserts can choose `append_shape: :columns` or `:rows` when one shape is known to fit a workload better. Omitted columns get their defaults, including sequence-backed IDs; use `QuackDB.Sequence.next_values/4` only when you need the IDs before the write. See the [type support guide](type-support.md), [getting started guide](getting-started.md), and the [Explorer guide](explorer.md).

## DML builders

Small DML builders can keep setup/cleanup SQL readable while preserving query parameters:

```elixir
{sql, params} =
  QuackDB.DML.delete_from(:events,
    where: [event_type: "session_entry", session_file: session_file]
  )

QuackDB.query!(conn, sql, params, timeout: :infinity)
```

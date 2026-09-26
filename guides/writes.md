# Writes

QuackDB writes through DuckDB's native append protocol instead of generating `INSERT VALUES` statements: rows, columns, Explorer dataframes, `Table.Reader` data, and streams, from a connection or a QuackDB-backed Ecto Repo.

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

Explicit MAP columns accept ordinary Elixir maps while plain map inference stays STRUCT-shaped:

```elixir
QuackDB.insert_rows!(conn, "events", [[id: 1, labels: %{env: "prod", region: "eu"}]],
  columns: [id: :integer, labels: {:map, :varchar, :varchar}]
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
|> Stream.map(&Jason.decode!/1)
|> QuackDB.insert_stream!(MyApp.AnalyticsRepo, "events", chunk_every: 10_000)
```

Any `Table.Reader`-compatible data can be appended through the same column append path:

```elixir
QuackDB.insert_table!(conn, "events", %{id: [1, 2], name: ["duck", "goose"]})
```

## Types, batching, and Ecto

Append supports explicit types, batching, scalar DuckDB values, and nested `LIST`, `STRUCT`, `ARRAY`, and `MAP` values. Ecto `insert_all(..., insert_method: :append)` can use schema types for nullable batches, omitted/defaulted columns, and `RETURNING` through a temporary append table; that multi-statement staging workflow runs in one transaction so it retains one DuckDB session. Direct append inserts can choose `append_shape: :columns` or `:rows` when one shape is known to fit a workload better. Native append does not evaluate column defaults; use `QuackDB.Sequence.for_column/4` or `QuackDB.Ecto.column_sequence_name/2` with `QuackDB.Sequence.next_values/4` when you need to preallocate sequence-backed IDs before appending explicit primary keys. See the [type support guide](type-support.md), [getting started guide](getting-started.md), and the [Explorer guide](explorer.md).

## DML builders

Small DML builders can keep setup/cleanup SQL readable while preserving query parameters:

```elixir
{sql, params} =
  QuackDB.DML.delete_from(:events,
    where: [event_type: "session_entry", session_file: session_file]
  )

QuackDB.query!(conn, sql, params, timeout: :infinity)
```

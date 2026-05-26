# Explorer and Table.Reader

QuackDB can hand query results to Explorer and can append Explorer dataframes through Quack's native column append protocol.

The Explorer integration is optional. Add Explorer when you want dataframe helpers:

```elixir
{:quackdb, "~> 0.2.0"},
{:explorer, "~> 0.11"}
```

## Query into a dataframe

Prefer Ecto queries when you have schemas or source helpers:

```elixir
use QuackDB.Ecto

alias QuackDB.Explorer, as: QuackExplorer

query =
  from event in Event,
    group_by: event.category,
    select: %{category: event.category, avg_score: avg(event.score)}

summary = QuackExplorer.dataframe!(conn, query)
```

## Append a dataframe

```elixir
alias Explorer.DataFrame
alias QuackDB.Explorer, as: QuackExplorer

df =
  DataFrame.new(
    id: [1, 2, 3],
    category: ["alpha", "alpha", "beta"],
    score: [10.0, 20.0, 15.0]
  )

QuackExplorer.insert_dataframe!(conn, "events", df, batch_size: 10_000)
```

This uses `QuackDB.insert_columns/4` internally, preserving Explorer's columnar shape instead of converting the dataframe into row maps.

`QuackDB.Explorer.dataframe/4` also accepts raw SQL when needed.

## Table.Reader

When the optional `:table` package is available, `QuackDB.Result` and `QuackDB.Columns` implement `Table.Reader`.

```elixir
result = QuackDB.query!(conn, "SELECT 1 AS id, 'duck' AS name")
Table.Reader.init(result)
```

Columnar results expose a column reader:

```elixir
columns = QuackDB.columnar!(conn, "SELECT 1 AS id, 'duck' AS name")
Table.Reader.init(columns)
```

This makes QuackDB friendlier to Livebook, Explorer, and Table-aware Elixir tooling.

See [`examples/dataframe_analytics.exs`](examples/dataframe_analytics.exs) for a runnable dataframe roundtrip.

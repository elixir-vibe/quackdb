# Explorer and Table.Reader

QuackDB can hand query results to Explorer and can append Explorer dataframes through Quack's native column append protocol.

The Explorer integration is optional. Add Explorer when you want dataframe helpers:

```elixir
{:quackdb, "~> 0.2.0"},
{:explorer, "~> 0.11"}
```

## Query into a dataframe

```elixir
{:ok, df} =
  QuackDB.Explorer.dataframe(conn, """
  SELECT category, avg(score) AS avg_score
  FROM events
  GROUP BY category
  ORDER BY category
  """)
```

`QuackDB.Explorer.dataframe/4` also accepts Ecto queries:

```elixir
import Ecto.Query

query =
  from event in Event,
    group_by: event.category,
    select: %{category: event.category, avg_score: avg(event.score)}

summary = QuackDB.Explorer.dataframe!(conn, query)
```

## Append a dataframe

```elixir
df =
  Explorer.DataFrame.new(
    id: [1, 2, 3],
    category: ["alpha", "alpha", "beta"],
    score: [10.0, 20.0, 15.0]
  )

QuackDB.Explorer.insert_dataframe!(conn, "events", df, batch_size: 10_000)
```

This uses `QuackDB.insert_columns/4` internally, preserving Explorer's columnar shape instead of converting the dataframe into row maps.

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

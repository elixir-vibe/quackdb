# Local file staging

DuckDB source functions can read CSV, JSON, Parquet, and other files directly. When DuckDB runs in a separate Quack server, that server may not be able to see local files from the Elixir process.

`QuackDB.Stage` bridges that gap by temporarily serving a local file over HTTP for the duration of a callback.

## Stage a file

```elixir
QuackDB.Stage.with_file("events.csv", fn staged ->
  source = QuackDB.Source.csv(staged.url, header: true)

  QuackDB.query!(conn, [
    "SELECT category, count(*) FROM ",
    source,
    " GROUP BY category"
  ])
end)
```

The callback receives:

```elixir
%{
  url: "http://127.0.0.1:.../token/events.csv",
  path: "/absolute/path/events.csv",
  file_name: "events.csv",
  token: "...",
  port: 12345
}
```

The temporary HTTP server is shut down when the callback returns or raises.

## Explorer example

```elixir
QuackDB.Stage.with_file("events.csv", fn staged ->
  source = QuackDB.Source.csv(staged.url, header: true)

  QuackDB.Explorer.dataframe!(conn, [
    "SELECT category, avg(score) AS avg_score FROM ",
    source,
    " GROUP BY category ORDER BY category"
  ])
end)
```

See [`examples/local_file_analytics.exs`](examples/local_file_analytics.exs) for a runnable example.

## Notes

- Staging serves one file for the callback duration.
- The URL contains a random token path.
- The current implementation is intended for local demos, notebooks, and controlled workflows, not as a general-purpose static file server.
- For remote DuckDB servers on another machine, ensure the server can reach the staged URL.

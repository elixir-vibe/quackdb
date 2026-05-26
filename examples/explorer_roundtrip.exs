Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:explorer, "~> 0.11"}
])

alias Explorer.DataFrame

uri = System.get_env("QUACKDB_TEST_URI", "http://localhost:9494")
token = System.get_env("QUACKDB_TEST_TOKEN", "super_secret")

{:ok, conn} = QuackDB.start_link(uri: uri, token: token)

table = "explorer_events_#{System.unique_integer([:positive])}"

QuackDB.query!(conn, "CREATE TEMP TABLE #{table}(id INTEGER, category VARCHAR, score DOUBLE)")

df =
  DataFrame.new(
    id: [1, 2, 3, 4],
    category: ["alpha", "alpha", "beta", "beta"],
    score: [10.0, 20.0, 15.0, 25.0]
  )

QuackDB.Explorer.insert_dataframe!(conn, table, df, batch_size: 2)

summary =
  QuackDB.Explorer.dataframe!(conn, """
  SELECT category, count(*) AS events, avg(score) AS avg_score
  FROM #{table}
  GROUP BY category
  ORDER BY category
  """)

IO.inspect(summary, label: "summary dataframe")

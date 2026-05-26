Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:jason, "~> 1.4"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

alias QuackDB.DDL

%{conn: conn} = QuackDBDemo.start_connection()

table = "streamed_events_#{System.unique_integer([:positive])}"

QuackDB.query!(
  conn,
  DDL.create_table(table, [id: :integer, name: :varchar, score: :integer], temporary: true)
)

ndjson = """
{"id":1,"name":"duck","score":10}
{"id":2,"name":"goose","score":20}
{"id":3,"name":"salmon","score":5}
"""

rows =
  ndjson
  |> String.split("\n", trim: true)
  |> Stream.map(fn line ->
    line
    |> Jason.decode!()
    |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
  end)

QuackDB.insert_stream!(conn, table, rows, chunk_every: 2)

result =
  QuackDB.query!(
    conn,
    "SELECT name, score FROM #{table} WHERE score >= 10 ORDER BY score DESC"
  )

IO.inspect(result.rows, label: "streamed rows")

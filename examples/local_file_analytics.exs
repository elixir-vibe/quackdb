Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:explorer, "~> 0.11"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

%{conn: conn} = QuackDBDemo.start_connection()

path =
  Path.join(System.tmp_dir!(), "quackdb-local-events-#{System.unique_integer([:positive])}.csv")

File.write!(path, """
id,category,score
1,alpha,10.0
2,alpha,20.0
3,beta,15.0
4,beta,25.0
""")

try do
  QuackDB.Stage.with_file(path, fn staged ->
    source = QuackDB.Source.csv(staged.url, header: true)

    df =
      QuackDB.Explorer.dataframe!(conn, [
        "SELECT category, count(*) AS events, avg(score) AS avg_score ",
        "FROM ",
        source,
        " GROUP BY category ORDER BY category"
      ])

    IO.inspect(df, label: "local CSV analytics")
  end)
after
  File.rm(path)
end

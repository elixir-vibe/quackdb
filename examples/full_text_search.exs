Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:ecto_sql, "~> 3.13"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

defmodule FullTextSearchExample.Repo do
  use Ecto.Repo,
    otp_app: :full_text_search_example,
    adapter: Ecto.Adapters.QuackDB
end

defmodule FullTextSearchExample do
  import Ecto.Query
  import QuackDB.Ecto.FullTextSearch

  alias FullTextSearchExample.Repo
  alias QuackDB.{DML, FullTextSearch}

  def run do
    %{conn: conn} = QuackDBDemo.start_connection()

    Application.put_env(:full_text_search_example, Repo,
      uri: connection_uri(),
      token: connection_token(),
      pool_size: 1,
      log: false
    )

    {:ok, _repo} = Repo.start_link()

    table = "search_documents_#{System.unique_integer([:positive])}"

    QuackDB.query!(
      conn,
      QuackDB.DDL.create_table(table, id: :integer, title: :varchar, body: :varchar)
    )

    QuackDB.query!(
      conn,
      DML.insert_into(table, [
        [id: 1, title: "DuckDB analytics", body: "Columnar analytics with DuckDB and Elixir"],
        [id: 2, title: "Goose field notes", body: "A short note about geese and wetlands"],
        [id: 3, title: "Quack protocol", body: "Remote DuckDB queries over the Quack protocol"]
      ])
    )

    QuackDB.query!(conn, FullTextSearch.install())
    QuackDB.query!(conn, FullTextSearch.load())

    QuackDB.query!(
      conn,
      FullTextSearch.create_index(table, :id, [:title, :body],
        stemmer: :none,
        stopwords: :none,
        overwrite: true
      )
    )

    schema = FullTextSearch.schema_name("main.#{table}")
    score = FullTextSearch.match_bm25(~s|"id"|, "DuckDB", schema: schema)

    direct =
      QuackDB.query!(conn, [
        "SELECT id, title, ",
        score,
        " AS score FROM ",
        table,
        " WHERE ",
        score,
        " > 0 ORDER BY score DESC"
      ])

    IO.inspect(direct.rows, label: "direct SQL search")

    ecto =
      from(doc in table,
        where: match_bm25(^schema, doc.id, ^"DuckDB") > 0,
        order_by: [desc: match_bm25(^schema, doc.id, ^"DuckDB")],
        select: %{id: doc.id, title: doc.title, score: match_bm25(^schema, doc.id, ^"DuckDB")}
      )
      |> Repo.all()

    IO.inspect(ecto, label: "Ecto search")
  end

  defp connection_uri, do: System.get_env("QUACKDB_URI", "http://[::1]:9494")
  defp connection_token, do: System.get_env("QUACKDB_TOKEN", "super_secret")
end

FullTextSearchExample.run()

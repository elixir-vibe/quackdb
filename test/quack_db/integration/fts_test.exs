defmodule QuackDB.Integration.FullTextSearchTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.Ecto.FullTextSearch

  alias QuackDB.FullTextSearch, as: FTS
  alias QuackDB.TestHelper

  @moduletag :integration

  test "full-text search helpers build and query an FTS index" do
    start_repo!()
    table = "quackdb_fts_documents"

    QuackDB.IntegrationRepo.query!("DROP TABLE IF EXISTS #{table}")

    TestHelper.create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      title: :varchar,
      body: :varchar
    )

    assert {3, nil} =
             QuackDB.IntegrationRepo.insert_all(table, [
               [
                 id: 1,
                 title: "DuckDB analytics",
                 body: "Columnar analytics with DuckDB and Elixir"
               ],
               [id: 2, title: "Goose story", body: "A short note about geese"],
               [
                 id: 3,
                 title: "Quack protocol",
                 body: "Remote DuckDB queries over the Quack protocol"
               ]
             ])

    QuackDB.IntegrationRepo.query!(FTS.install())
    QuackDB.IntegrationRepo.query!(FTS.load())

    QuackDB.IntegrationRepo.query!(
      FTS.create_index(table, :id, [:title, :body],
        stemmer: :none,
        stopwords: :none,
        overwrite: true
      )
    )

    query =
      from(doc in table,
        where: match_bm25("fts_main_quackdb_fts_documents", doc.id, ^"DuckDB") > 0,
        order_by: [desc: match_bm25("fts_main_quackdb_fts_documents", doc.id, ^"DuckDB")],
        select: %{
          id: doc.id,
          title: doc.title,
          score: match_bm25("fts_main_quackdb_fts_documents", doc.id, ^"DuckDB")
        }
      )

    assert [%{id: id, title: title, score: score} | _rest] = QuackDB.IntegrationRepo.all(query)
    assert id in [1, 3]
    assert title in ["DuckDB analytics", "Quack protocol"]
    assert score > 0

    QuackDB.IntegrationRepo.query!(FTS.drop_index(table))
  end
end

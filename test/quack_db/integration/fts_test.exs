defmodule QuackDB.Integration.FTSTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.Ecto.FTS

  alias QuackDB.FTS
  alias QuackDB.TestHelper

  @moduletag :integration

  test "full-text search options support field filters and conjunctive queries" do
    start_repo!()
    table = "quackdb_fts_options"

    QuackDB.IntegrationRepo.query!("DROP TABLE IF EXISTS #{table}")

    TestHelper.create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      title: :varchar,
      body: :varchar
    )

    QuackDB.IntegrationRepo.insert_all(table, [
      [id: 1, title: "DuckDB protocol", body: "Elixir analytics"],
      [id: 2, title: "DuckDB only", body: "Protocol notes"],
      [id: 3, title: "Elixir only", body: "DuckDB protocol"]
    ])

    QuackDB.IntegrationRepo.query!(FTS.install())
    QuackDB.IntegrationRepo.query!(FTS.load())

    QuackDB.IntegrationRepo.query!(
      FTS.create_index(table, :id, :all, stemmer: :none, stopwords: :none, overwrite: true)
    )

    schema = "fts_main_quackdb_fts_options"

    title_only =
      QuackDB.IntegrationRepo.query!([
        "SELECT id FROM ",
        table,
        " WHERE ",
        FTS.match_bm25(~s|"id"|, "DuckDB", schema: schema, fields: :title),
        " > 0 ORDER BY id"
      ])

    assert title_only.rows == [[1], [2]]

    conjunctive =
      QuackDB.IntegrationRepo.query!([
        "SELECT id FROM ",
        table,
        " WHERE ",
        FTS.match_bm25(~s|"id"|, "DuckDB protocol", schema: schema, conjunctive: true),
        " > 0 ORDER BY id"
      ])

    assert conjunctive.rows == [[1], [2], [3]]

    QuackDB.IntegrationRepo.query!(FTS.drop_index(table))
  end

  test "FTS aliases and stemming run against DuckDB" do
    start_repo!()

    QuackDB.IntegrationRepo.query!(FTS.install())
    QuackDB.IntegrationRepo.query!(FTS.load())

    assert %{rows: [["run"]]} =
             QuackDB.IntegrationRepo.query!(["SELECT ", FTS.stem("'running'", :porter)])

    assert FTS.bm25(~s|"id"|, "duck", schema: "fts_main_documents") ==
             FTS.match_bm25(~s|"id"|, "duck", schema: "fts_main_documents")

    assert FTS.search_score(~s|"id"|, "duck", schema: "fts_main_documents") ==
             FTS.match_bm25(~s|"id"|, "duck", schema: "fts_main_documents")
  end

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

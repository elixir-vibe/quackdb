defmodule QuackDB.FTSTest do
  use ExUnit.Case, async: true

  alias QuackDB.FTS

  test "builds extension statements" do
    assert FTS.install() |> IO.iodata_to_binary() == "INSTALL fts;"
    assert FTS.load() |> IO.iodata_to_binary() == "LOAD fts;"
  end

  test "builds create and drop index pragmas" do
    assert FTS.create_index("documents", :id, [:title, :body], overwrite: true)
           |> IO.iodata_to_binary() ==
             "PRAGMA create_fts_index('documents', 'id', 'title', 'body', overwrite = 1);"

    assert FTS.create_index("main.documents", :id, :all, stemmer: :none, stopwords: :none)
           |> IO.iodata_to_binary() ==
             "PRAGMA create_fts_index('main.documents', 'id', '*', stemmer = 'none', stopwords = 'none');"

    assert FTS.drop_index("documents") |> IO.iodata_to_binary() ==
             "PRAGMA drop_fts_index('documents');"
  end

  test "builds match and stem expressions" do
    assert FTS.schema_name("main.documents") == "fts_main_documents"

    assert FTS.match_bm25(~s|"id"|, "duck search",
             fields: [:title, :body],
             k: 1.1,
             b: 0.8,
             conjunctive: true
           )
           |> IO.iodata_to_binary() ==
             ~s|match_bm25("id", 'duck search', fields := 'title, body', k := 1.1, b := 0.8, conjunctive := 1)|

    assert FTS.match_bm25(~s|"id"|, "duck search", schema: "fts_main_documents")
           |> IO.iodata_to_binary() ==
             ~s|"fts_main_documents".match_bm25("id", 'duck search')|

    assert FTS.stem(~s|"body"|, :english) |> IO.iodata_to_binary() ==
             ~s|stem("body", 'english')|
  end
end

defmodule QuackDB.Ecto.SQLGeneration.FTSTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.FTS

  alias Ecto.Adapters.QuackDB.Query

  test "generates schema-qualified match_bm25 expressions" do
    query =
      from(doc in "documents",
        where: match_bm25("fts_main_documents", doc.id, ^"duck search") > 0,
        select: %{id: doc.id, rank: match_bm25("fts_main_documents", doc.id, ^"duck search")}
      )

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."id" AS "id", "fts_main_documents".match_bm25(q0."id", ?) AS "rank" FROM "documents" AS q0 WHERE ("fts_main_documents".match_bm25(q0."id", ?) > 0)|
  end

  test "generates match_bm25 expressions" do
    query =
      from(doc in "documents",
        where: match_bm25(doc.id, ^"duck search") > 0,
        order_by: [desc: match_bm25(doc.id, ^"duck search")],
        select: %{id: doc.id, rank: match_bm25(doc.id, ^"duck search")}
      )

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."id" AS "id", match_bm25(q0."id", ?) AS "rank" FROM "documents" AS q0 WHERE (match_bm25(q0."id", ?) > 0) ORDER BY match_bm25(q0."id", ?) DESC|
  end
end

defmodule QuackDB.Ecto.SQLGeneration.FragmentsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "generates DuckDB analytical aggregate fragments" do
    query =
      from(event in "events",
        group_by: event.category_id,
        select: %{
          category_id: event.category_id,
          median_score: fragment("median(?)", event.score),
          p95_score: fragment("quantile_cont(?, 0.95)", event.score),
          scores: fragment("list(?)", event.score)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."category_id" AS "category_id", median(q0."score") AS "median_score", quantile_cont(q0."score", 0.95) AS "p95_score", list(q0."score") AS "scores" FROM "events" AS q0 GROUP BY q0."category_id"]
  end

  test "generates nested/list expression fragments" do
    query =
      from(event in "events",
        select: %{
          doubled: fragment("list_transform(?, x -> x * 2)", event.scores),
          first_tag: fragment("?[1]", event.tags),
          object_name: fragment("?.name", event.payload)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~s|SELECT list_transform(q0."scores", x -> x * 2) AS "doubled", q0."tags"[1] AS "first_tag", q0."payload".name AS "object_name" FROM "events" AS q0|
  end
end

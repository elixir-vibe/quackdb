defmodule QuackDB.Ecto.SQLGeneration.AnalyticalTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  test "generates Ecto SQL with CTEs" do
    cte_query =
      from(event in "events",
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    query =
      "recent"
      |> with_cte("recent", as: ^cte_query)
      |> select([event], %{id: event.id})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[WITH "recent" AS (SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0 WHERE (q0."id" > 1)) SELECT q0."id" AS "id" FROM "recent" AS q0]
  end

  test "generates Ecto SQL with window functions" do
    query =
      from(event in "events",
        windows: [by_kind: [partition_by: event.kind, order_by: [desc: event.id]]],
        select: %{
          row_number: over(row_number(), :by_kind),
          running_score: over(sum(event.score), :by_kind)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT ROW_NUMBER() OVER "by_kind" AS "row_number", SUM(q0."score") OVER "by_kind" AS "running_score" FROM "events" AS q0 WINDOW "by_kind" AS (PARTITION BY q0."kind" ORDER BY q0."id" DESC)]
  end

  test "generates analytical Ecto SQL with joins groupings and having" do
    query =
      from(event in "events",
        join: category in "categories",
        on: event.category_id == category.id,
        group_by: [event.category_id, category.name],
        having: count(event.id) > 1,
        select: %{category: category.name, count: count(event.id)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q1."name" AS "category", COUNT(q0."id") AS "count" FROM "events" AS q0 INNER JOIN "categories" AS q1 ON (q0."category_id" = q1."id") GROUP BY q0."category_id", q1."name" HAVING (COUNT(q0."id") > 1)]
  end
end

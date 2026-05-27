defmodule QuackDB.Ecto.SQLGeneration.WindowFunctionsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "generates ranking window functions" do
    query =
      from(event in "events",
        windows: [by_category: [partition_by: event.category_id, order_by: [desc: event.score]]],
        select: %{
          row_number: over(row_number(), :by_category),
          rank: over(rank(), :by_category),
          dense_rank: over(dense_rank(), :by_category),
          percent_rank: over(percent_rank(), :by_category),
          cume_dist: over(cume_dist(), :by_category)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT ROW_NUMBER() OVER "by_category" AS "row_number", RANK() OVER "by_category" AS "rank", DENSE_RANK() OVER "by_category" AS "dense_rank", PERCENT_RANK() OVER "by_category" AS "percent_rank", CUME_DIST() OVER "by_category" AS "cume_dist" FROM "events" AS q0 WINDOW "by_category" AS (PARTITION BY q0."category_id" ORDER BY q0."score" DESC)]
  end

  test "generates subquery form for qualify-style filters" do
    ranked =
      from(event in "events",
        windows: [by_category: [partition_by: event.category_id, order_by: [desc: event.score]]],
        select: %{
          id: event.id,
          category_id: event.category_id,
          rank: over(row_number(), :by_category)
        }
      )

    query =
      from(event in subquery(ranked),
        where: event.rank <= 3,
        order_by: [event.category_id, event.rank],
        select: %{id: event.id, rank: event.rank}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id", q0."rank" AS "rank" FROM (SELECT q0."id" AS "id", q0."category_id" AS "category_id", ROW_NUMBER() OVER "by_category" AS "rank" FROM "events" AS q0 WINDOW "by_category" AS (PARTITION BY q0."category_id" ORDER BY q0."score" DESC)) AS q0 WHERE (q0."rank" <= 3) ORDER BY q0."category_id" ASC, q0."rank" ASC]
  end

  test "generates value window functions" do
    query =
      from(event in "events",
        select: %{
          previous_score: over(lag(event.score), :by_category),
          next_score: over(lead(event.score, 2, 0), :by_category),
          first_score: over(first_value(event.score), :by_category),
          last_score: over(last_value(event.score), :by_category),
          second_score: over(nth_value(event.score, 2), :by_category)
        },
        windows: [by_category: [partition_by: event.category_id, order_by: [asc: event.id]]]
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT lag(q0."score") OVER "by_category" AS "previous_score", lead(q0."score", 2, 0) OVER "by_category" AS "next_score", first_value(q0."score") OVER "by_category" AS "first_score", last_value(q0."score") OVER "by_category" AS "last_score", nth_value(q0."score", 2) OVER "by_category" AS "second_score" FROM "events" AS q0 WINDOW "by_category" AS (PARTITION BY q0."category_id" ORDER BY q0."id" ASC)]
  end

  test "generates framed window definitions" do
    query =
      from(event in "events",
        select: %{
          rolling_score:
            over(sum(event.score),
              partition_by: event.category_id,
              order_by: [asc: event.id],
              frame: fragment("ROWS BETWEEN 6 PRECEDING AND CURRENT ROW")
            )
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT SUM(q0."score") OVER (PARTITION BY q0."category_id" ORDER BY q0."id" ASC ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS "rolling_score" FROM "events" AS q0]
  end

  test "generates inline window definitions" do
    query =
      from(event in "events",
        select: %{
          running_score:
            over(sum(event.score), partition_by: event.category_id, order_by: [asc: event.id])
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT SUM(q0."score") OVER (PARTITION BY q0."category_id" ORDER BY q0."id" ASC) AS "running_score" FROM "events" AS q0]
  end
end

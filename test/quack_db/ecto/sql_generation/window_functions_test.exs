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

defmodule QuackDB.Ecto.SQLGeneration.AggregatesTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  test "generates read-only Ecto SQL for aggregates and common predicates" do
    query =
      from(event in "events",
        where: like(event.name, "d%") and not is_nil(event.name),
        select: %{count: count(event.id)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COUNT(q0."id") AS "count" FROM "events" AS q0 WHERE ((q0."name" LIKE 'd%') AND (q0."name" IS NOT NULL))]
  end

  test "generates aggregate FILTER expressions" do
    query =
      from(event in "events",
        select: %{duck_count: filter(count(event.id), event.kind == "duck")}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COUNT(q0."id") FILTER (WHERE (q0."kind" = ?)) AS "duck_count" FROM "events" AS q0]
  end

  test "generates distinct count and coalesce expressions" do
    query =
      from(event in "events",
        select: %{
          distinct_users: count(event.user_id, :distinct),
          score_or_zero: coalesce(event.score, 0)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COUNT(DISTINCT q0."user_id") AS "distinct_users", coalesce(q0."score", 0) AS "score_or_zero" FROM "events" AS q0]
  end
end

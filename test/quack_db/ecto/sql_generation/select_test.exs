defmodule QuackDB.Ecto.SQLGeneration.SelectTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  test "generates basic read-only Ecto select SQL" do
    query =
      from(event in "events",
        where: event.id > 1 and event.name != "goose",
        order_by: [asc: event.id],
        limit: 10,
        offset: 2,
        select: %{id: event.id, name: event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0 WHERE ((q0."id" > ?) AND (q0."name" <> ?)) ORDER BY q0."id" ASC LIMIT 10 OFFSET 2]
  end

  test "generates read-only Ecto SQL for fragments" do
    query = from(event in "events", select: %{upper_name: fragment("upper(?)", event.name)})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT upper(q0."name") AS "upper_name" FROM "events" AS q0]
  end

  test "generates IN subquery SQL" do
    inner_query = from(other in "other", where: other.kind == "duck", select: other.event_id)
    query = from(event in "events", where: event.id in subquery(inner_query), select: event.id)

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE (q0."id" IN (SELECT q0."event_id" FROM "other" AS q0 WHERE (q0."kind" = ?)))]
  end

  test "generates nested tuple and map select SQL" do
    query =
      from(event in "events",
        select: {%{id: event.id, name: event.name}, {event.category_id, event.score}}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id", q0."name" AS "name", q0."category_id", q0."score" FROM "events" AS q0]
  end

  test "generates distinct and richer predicate Ecto SQL" do
    query =
      from(event in "events",
        distinct: [asc: event.category_id],
        where: event.category_id in [1, 2, 3] and not (event.score < 10),
        select: %{category_id: event.category_id, adjusted_score: event.score + 5}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT DISTINCT ON (q0."category_id") q0."category_id" AS "category_id", (q0."score" + 5) AS "adjusted_score" FROM "events" AS q0 WHERE ((q0."category_id" IN (1, 2, 3)) AND (NOT (q0."score" < ?)))]
  end
end

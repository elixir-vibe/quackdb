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
             ~S[SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0 WHERE ((q0."id" > 1) AND (q0."name" <> 'goose')) ORDER BY q0."id" ASC LIMIT 10 OFFSET 2]
  end

  test "generates read-only Ecto SQL for fragments" do
    query = from(event in "events", select: %{upper_name: fragment("upper(?)", event.name)})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT upper(q0."name") AS "upper_name" FROM "events" AS q0]
  end

  test "generates distinct and richer predicate Ecto SQL" do
    query =
      from(event in "events",
        distinct: [asc: event.category_id],
        where: event.category_id in [1, 2, 3] and not (event.score < 10),
        select: %{category_id: event.category_id, adjusted_score: event.score + 5}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT DISTINCT ON (q0."category_id") q0."category_id" AS "category_id", (q0."score" + 5) AS "adjusted_score" FROM "events" AS q0 WHERE ((q0."category_id" IN (1, 2, 3)) AND (NOT (q0."score" < 10)))]
  end
end

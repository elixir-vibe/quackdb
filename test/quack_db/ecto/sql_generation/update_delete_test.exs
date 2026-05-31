defmodule QuackDB.Ecto.SQLGeneration.UpdateDeleteTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.QuackDB.Connection

  test "generates update_all SQL" do
    query =
      from(event in "events",
        where: event.id == ^1,
        update: [set: [name: ^"duck"], inc: [score: 1]]
      )

    sql = query |> Connection.update_all() |> IO.iodata_to_binary()

    assert sql ==
             ~s|UPDATE "events" AS q0 SET "score" = "score" + ?, "name" = ? WHERE (q0."id" = ?)|
  end

  test "generates joined update_all SQL" do
    query =
      from(event in "events",
        join: category in "categories",
        on: category.id == event.category_id,
        where: category.name == ^"birds",
        update: [set: [name: category.name]]
      )

    sql = query |> Connection.update_all() |> IO.iodata_to_binary()

    assert sql ==
             ~s|UPDATE "events" AS q0 SET "name" = q1."name" FROM "categories" AS q1 WHERE (q1."id" = q0."category_id") AND (q1."name" = ?)|
  end

  test "generates ordered limited update_all SQL through rowid filter" do
    query =
      from(event in "events",
        order_by: [asc: event.id],
        limit: 1,
        update: [set: [name: ^"duck"]]
      )

    sql = query |> Connection.update_all() |> IO.iodata_to_binary()

    assert sql ==
             ~s|UPDATE "events" AS q0 SET "name" = ? WHERE q0.rowid IN (SELECT q0.rowid FROM "events" AS q0 ORDER BY q0."id" ASC LIMIT 1)|
  end

  test "generates schema update SQL" do
    sql =
      Connection.update(nil, "events", [name: "duck"], [id: 1], [:id])
      |> IO.iodata_to_binary()

    assert sql == ~s|UPDATE "events" SET "name" = ? WHERE "id" = ? RETURNING "id"|
  end

  test "generates schema delete SQL" do
    sql =
      Connection.delete(nil, "events", [id: 1], [])
      |> IO.iodata_to_binary()

    assert sql == ~s|DELETE FROM "events" WHERE "id" = ?|
  end

  test "generates delete_all SQL" do
    query = from(event in "events", where: event.id in ^[1, 2])

    sql = query |> Connection.delete_all() |> IO.iodata_to_binary()

    assert sql == ~s|DELETE FROM "events" AS q0 WHERE (q0."id" IN ?)|
  end

  test "generates joined delete_all SQL" do
    query =
      from(event in "events",
        join: category in "categories",
        on: category.id == event.category_id,
        where: category.name == ^"birds"
      )

    sql = query |> Connection.delete_all() |> IO.iodata_to_binary()

    assert sql ==
             ~s|DELETE FROM "events" AS q0 USING "categories" AS q1 WHERE (q1."id" = q0."category_id") AND (q1."name" = ?)|
  end
end

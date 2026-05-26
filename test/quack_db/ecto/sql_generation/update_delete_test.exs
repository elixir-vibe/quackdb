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
             ~s|UPDATE "events" AS q0 SET "score" = "score" + 1, "name" = ? WHERE (q0."id" = ?)|
  end

  test "generates delete_all SQL" do
    query = from(event in "events", where: event.id in ^[1, 2])

    sql = query |> Connection.delete_all() |> IO.iodata_to_binary()

    assert sql == ~s|DELETE FROM "events" AS q0 WHERE (q0."id" IN ?)|
  end

  test "rejects joined update_all" do
    query =
      from(event in "events",
        join: category in "categories",
        on: category.id == event.category_id,
        update: [set: [name: ^"duck"]]
      )

    assert_raise QuackDB.Error, ~r/update_all\/delete_all with joins is unsupported/, fn ->
      Connection.update_all(query)
    end
  end
end

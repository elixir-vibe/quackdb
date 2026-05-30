defmodule QuackDB.Ecto.SQLGeneration.PinnedListTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "generates IN expressions for pinned lists" do
    values = ["a", "b"]

    query = from(row in "events", where: row.sha256 in ^values, select: row.id)

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE (q0."sha256" IN ?)]
  end
end

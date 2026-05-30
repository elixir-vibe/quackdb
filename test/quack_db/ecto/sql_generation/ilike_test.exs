defmodule QuackDB.Ecto.SQLGeneration.ILikeTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "generates ILIKE expressions" do
    query = from(row in "events", where: ilike(row.name, ^"%duck%"), select: row.id)

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE (q0."name" ILIKE ?)]
  end
end

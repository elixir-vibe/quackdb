defmodule QuackDB.Ecto.SQLGeneration.UnsupportedTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  test "Ecto combinations generate SQL" do
    other_query = from(other in "other", select: other.id)
    query = from(event in "events", union: ^other_query, select: event.id)

    sql = query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary()

    assert sql == ~s|SELECT q0."id" FROM "events" AS q0 UNION SELECT q0."id" FROM "other" AS q0|
  end
end

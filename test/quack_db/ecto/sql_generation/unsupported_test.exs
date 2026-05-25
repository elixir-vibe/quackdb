defmodule QuackDB.Ecto.SQLGeneration.UnsupportedTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  test "unsupported Ecto query features raise explicit errors" do
    other_query = from(other in "other", select: other.id)
    query = from(event in "events", union: ^other_query, select: event.id)

    assert_raise QuackDB.Error, ~r/Ecto combinations are not supported yet/, fn ->
      Ecto.Adapters.QuackDB.Connection.all(query)
    end
  end
end

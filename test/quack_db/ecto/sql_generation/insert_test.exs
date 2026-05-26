defmodule QuackDB.Ecto.SQLGeneration.InsertTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB.Connection

  test "generates insert_all SQL with placeholders" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id, :name],
        [[:id, :name], [:id, :name]],
        {:raise, [], []},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("id", "name") VALUES (?, ?), (?, ?)|
  end

  test "generates insert SQL with returning" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:name],
        [[:name]],
        {:raise, [], []},
        [:id],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("name") VALUES (?) RETURNING "id"|
  end

  test "generates on conflict do nothing" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id],
        [[:id]],
        {:nothing, [], [:id]},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("id") VALUES (?) ON CONFLICT ("id") DO NOTHING|
  end

  test "rejects unsupported upserts" do
    assert_raise QuackDB.Error, ~r/Ecto upserts are unsupported/, fn ->
      Connection.insert(nil, "events", [:id], [[:id]], {[:name], [], [:id]}, [], [])
    end
  end
end

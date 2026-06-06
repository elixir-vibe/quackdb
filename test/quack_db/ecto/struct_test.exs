defmodule QuackDB.Ecto.StructTest do
  use ExUnit.Case, async: true

  test "focused import exposes natural struct helper names" do
    defmodule FocusedStructQuery do
      import Ecto.Query
      import QuackDB.Ecto.Struct

      def query do
        from(event in "events",
          where: contains(event.metadata, ^"duck"),
          select: %{
            name: extract(event.metadata, ^"name"),
            first: extract_at(event.tuple, 1),
            position: position(event.tuple, ^"duck"),
            values: values(event.metadata),
            merged: concat(event.metadata, fragment("{'score': 10}"))
          }
        )
      end
    end

    assert FocusedStructQuery.query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT struct_extract(q0."metadata", ?) AS "name", struct_extract_at(q0."tuple", 1) AS "first", struct_position(q0."tuple", ?) AS "position", struct_values(q0."metadata") AS "values", struct_concat(q0."metadata", {'score': 10}) AS "merged" FROM "events" AS q0 WHERE struct_contains(q0."metadata", ?)]
  end

  test "use QuackDB.Ecto exposes explicit struct aliases for ambiguous helpers" do
    defmodule BroadStructQuery do
      use QuackDB.Ecto

      def query do
        from(event in "events",
          where: contains_struct(event.metadata, ^"duck"),
          select: %{
            name: struct_extract(event.metadata, ^"name"),
            first: struct_extract_at(event.tuple, 1),
            position: struct_position(event.tuple, ^"duck"),
            values: struct_values(event.metadata),
            merged: struct_concat(event.metadata, fragment("{'score': 10}"))
          }
        )
      end
    end

    assert BroadStructQuery.query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT struct_extract(q0."metadata", ?) AS "name", struct_extract_at(q0."tuple", 1) AS "first", struct_position(q0."tuple", ?) AS "position", struct_values(q0."metadata") AS "values", struct_concat(q0."metadata", {'score': 10}) AS "merged" FROM "events" AS q0 WHERE struct_contains(q0."metadata", ?)]
  end
end

defmodule QuackDB.Ecto.MapTest do
  use ExUnit.Case, async: true

  test "focused import exposes natural map helper names" do
    defmodule FocusedMapQuery do
      import Ecto.Query
      import QuackDB.Ecto.Map

      def query do
        from(event in "events",
          where: contains(event.labels, ^"env"),
          select: %{
            size: cardinality(event.labels),
            keys: keys(event.labels),
            values: values(event.labels),
            entries: entries(event.labels),
            entry?: contains_entry(event.labels, ^"env", ^"prod"),
            value?: contains_value(event.labels, ^"prod"),
            env_values: extract(event.labels, ^"env"),
            env: extract_value(event.labels, ^"env"),
            merged: concat(event.labels, ^{:map, %{region: "eu"}})
          }
        )
      end
    end

    assert FocusedMapQuery.query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT cardinality(q0."labels") AS "size", map_keys(q0."labels") AS "keys", map_values(q0."labels") AS "values", map_entries(q0."labels") AS "entries", map_contains_entry(q0."labels", ?, ?) AS "entry?", map_contains_value(q0."labels", ?) AS "value?", map_extract(q0."labels", ?) AS "env_values", map_extract_value(q0."labels", ?) AS "env", map_concat(q0."labels", ?) AS "merged" FROM "events" AS q0 WHERE map_contains(q0."labels", ?)]
  end

  test "use QuackDB.Ecto exposes explicit map aliases for ambiguous helpers" do
    defmodule BroadMapQuery do
      use QuackDB.Ecto

      def query do
        from(event in "events",
          where: contains_map(event.labels, ^"env"),
          select: %{
            size: map_cardinality(event.labels),
            keys: map_keys(event.labels),
            values: map_values(event.labels),
            entries: map_entries(event.labels),
            entry?: contains_map_entry(event.labels, ^"env", ^"prod"),
            value?: contains_map_value(event.labels, ^"prod"),
            env_values: map_extract(event.labels, ^"env"),
            env: map_extract_value(event.labels, ^"env"),
            merged: map_concat(event.labels, ^{:map, %{region: "eu"}})
          }
        )
      end
    end

    assert BroadMapQuery.query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT cardinality(q0."labels") AS "size", map_keys(q0."labels") AS "keys", map_values(q0."labels") AS "values", map_entries(q0."labels") AS "entries", map_contains_entry(q0."labels", ?, ?) AS "entry?", map_contains_value(q0."labels", ?) AS "value?", map_extract(q0."labels", ?) AS "env_values", map_extract_value(q0."labels", ?) AS "env", map_concat(q0."labels", ?) AS "merged" FROM "events" AS q0 WHERE map_contains(q0."labels", ?)]
  end
end

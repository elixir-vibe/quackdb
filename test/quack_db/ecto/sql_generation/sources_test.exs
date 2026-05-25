defmodule QuackDB.Ecto.SQLGeneration.SourcesTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  test "generates Ecto SQL from DuckDB source helpers" do
    source = QuackDB.Source.csv("events.csv", header: true)

    query =
      from(event in source,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id", q0."name" AS "name" FROM read_csv('events.csv', header = TRUE) AS q0 WHERE (q0."id" > 1)]
  end

  test "generates Ecto SQL from source fragments" do
    query =
      from(event in fragment("read_csv(?)", ^"events.csv"),
        where: event.id > 1,
        select: %{id: event.id}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id" FROM read_csv(?) AS q0 WHERE (q0."id" > 1)]
  end

  test "generates Ecto SQL from subquery sources" do
    inner_query = from(event in "events", where: event.id > 1, select: %{id: event.id})
    query = from(event in subquery(inner_query), select: %{id: event.id})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id" FROM (SELECT q0."id" AS "id" FROM "events" AS q0 WHERE (q0."id" > 1)) AS q0]
  end
end

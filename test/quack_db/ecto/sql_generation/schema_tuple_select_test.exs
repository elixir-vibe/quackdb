defmodule QuackDB.Ecto.SQLGeneration.SchemaTupleSelectTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "generates schema source selects inside tuples" do
    query =
      from(event in {"events", QuackDB.TestSchemas.KeyedEvent},
        select: {event, event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() =~
             ~S[SELECT q0."id", q0."name", q0."score", q0."name" FROM "events" AS q0]
  end

  test "generates lateral subqueries with parent_as bindings" do
    latest_event =
      from(event in {"events", QuackDB.TestSchemas.KeyedEvent},
        where: event.id == parent_as(:parent).id,
        limit: 1
      )

    query =
      from(event in {"events", QuackDB.TestSchemas.KeyedEvent},
        as: :parent,
        inner_lateral_join: latest in subquery(latest_event),
        on: true,
        select: {latest, event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q1."id", q1."name", q1."score", q0."name" FROM "events" AS q0 INNER JOIN LATERAL (SELECT * FROM "events" AS s1_q0 WHERE (s1_q0."id" = q0."id") LIMIT 1) AS q1 ON TRUE]
  end
end

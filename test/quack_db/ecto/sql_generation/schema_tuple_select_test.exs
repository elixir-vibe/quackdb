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
end

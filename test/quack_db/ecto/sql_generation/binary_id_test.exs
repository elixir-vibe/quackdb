defmodule QuackDB.Ecto.SQLGeneration.BinaryIdTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.QuackDB.Query

  test "partial binary_id selects cast UUID strings to Ecto-loadable bytes" do
    scalar_query = from(event in QuackDB.TestSchemas.BinaryEvent, select: event.id)
    map_query = from(event in QuackDB.TestSchemas.BinaryEvent, select: %{id: event.id})

    assert scalar_query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT from_hex(replace(CAST(q0."id" AS VARCHAR), '-', '')) FROM "binary_events" AS q0|

    assert map_query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT from_hex(replace(CAST(q0."id" AS VARCHAR), '-', '')) AS "id" FROM "binary_events" AS q0|
  end

  test "full schema selects cast binary_id UUID strings to Ecto-loadable bytes" do
    query = from(event in QuackDB.TestSchemas.BinaryEvent, select: event)

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT from_hex(replace(CAST(q0."id" AS VARCHAR), '-', '')) AS "id", q0."payload" FROM "binary_events" AS q0|
  end
end

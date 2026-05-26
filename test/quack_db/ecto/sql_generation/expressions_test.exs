defmodule QuackDB.Ecto.SQLGeneration.ExpressionsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.QuackDB.Query

  test "generates selected_as aliases" do
    query =
      from(event in "events",
        select: %{name: selected_as(event.name, :event_name)},
        order_by: selected_as(:event_name)
      )

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."name" AS "event_name" FROM "events" AS q0 ORDER BY "event_name" ASC|
  end

  test "generates map selects" do
    query = from(event in "events", select: map(event, [:id, :name]))

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."id", q0."name" FROM "events" AS q0|
  end

  test "casts type expressions" do
    query = from(event in "events", where: type(event.id, :string) == ^"1", select: event.id)

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."id" FROM "events" AS q0 WHERE (CAST(q0."id" AS VARCHAR) = ?)|
  end
end

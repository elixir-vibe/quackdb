defmodule QuackDB.Ecto.SQLGeneration.ExpressionsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.QuackDB.Query

  defmodule Event do
    use Ecto.Schema

    @primary_key {:id, :string, []}
    schema "events" do
      field(:name, :string)
    end
  end

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

  test "generates planner-normalized schema projections and counts" do
    projection = from(event in Event, select: map(event, ^[:id, :name]))
    count = from(event in Event, select: count())

    assert prepared_sql(projection) ==
             ~s|SELECT q0."id", q0."name" FROM "events" AS q0|

    assert prepared_sql(count) == ~s|SELECT COUNT(*) FROM "events" AS q0|
  end

  test "casts type expressions" do
    query =
      from(event in "events",
        where:
          type(event.id, :string) == ^"1" and
            type(^"10.50", :decimal) > type(event.score, :decimal),
        select: %{
          id: event.id,
          occurred_on: type(event.occurred_at, :date),
          tags: type(event.tags, {:array, :string})
        }
      )

    assert query |> Query.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."id" AS "id", CAST(q0."occurred_at" AS DATE) AS "occurred_on", CAST(q0."tags" AS VARCHAR[]) AS "tags" FROM "events" AS q0 WHERE ((CAST(q0."id" AS VARCHAR) = ?) AND (CAST(? AS DECIMAL) > CAST(q0."score" AS DECIMAL)))|
  end

  defp prepared_sql(query) do
    {planned, _params, _cache_key} =
      Ecto.Query.Planner.plan(query, :all, Ecto.Adapters.QuackDB)

    {normalized, _decoder} =
      Ecto.Query.Planner.normalize(planned, :all, Ecto.Adapters.QuackDB, 0)

    normalized
    |> Query.all()
    |> IO.iodata_to_binary()
  end
end

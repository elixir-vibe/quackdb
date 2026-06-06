defmodule QuackDB.Ecto.SQLGeneration.StarTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Star

  test "renders star expressions in selects" do
    query =
      from(event in "events",
        select: star(exclude: [:payload])
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT * EXCLUDE ("payload") FROM "events" AS q0]
  end

  test "renders columns expressions in predicates" do
    query =
      from(event in "events",
        where: columns(exclude: [:payload]) > 0,
        select: event.id
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE (COLUMNS(* EXCLUDE ("payload")) > 0)]
  end

  test "renders dynamic pinned columns selectors" do
    fields = [:score, :blah]
    pattern = "^metric_"

    columns_query =
      from(event in "events",
        where: columns(^fields) > 0,
        select: event.id
      )

    unpack_query =
      from(event in "events",
        select: unpack_columns(^pattern)
      )

    assert columns_query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE (COLUMNS(?) > 0)]

    assert unpack_query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT *COLUMNS(?) FROM "events" AS q0]
  end

  test "renders regex columns and unpacked columns" do
    regex_query =
      from(event in "events",
        select: columns("^metric_")
      )

    unpack_query =
      from(event in "events",
        select: unpack_columns([:metric_a, :metric_b])
      )

    assert regex_query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COLUMNS('^metric_') FROM "events" AS q0]

    assert unpack_query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             "SELECT *COLUMNS(['metric_a', 'metric_b']) FROM \"events\" AS q0"
  end

  test "use QuackDB.Ecto imports star helpers by default" do
    defmodule StarImports do
      use QuackDB.Ecto

      def query do
        from(event in "events", select: columns(exclude: [:payload]))
      end
    end

    assert StarImports.query() |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COLUMNS(* EXCLUDE ("payload")) FROM "events" AS q0]
  end
end

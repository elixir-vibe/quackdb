defmodule QuackDB.Ecto.PredicatesTest do
  use ExUnit.Case, async: true

  test "dispatches contains to text or spatial SQL from macro-expanded arguments" do
    defmodule Query do
      use QuackDB.Ecto

      def text_query do
        from(event in "events",
          where: contains(event.name, "duck"),
          select: event.name
        )
      end

      def pinned_text_query(needle) do
        from(event in "events",
          where: contains(event.name, ^needle),
          select: event.name
        )
      end

      def json_text_query do
        from(event in "events",
          where: contains(event.payload["name"], "duck"),
          select: event.id
        )
      end

      def spatial_query do
        from(event in "events",
          where: contains(envelope(0, 0, 10, 10), event.geom),
          select: event.id
        )
      end

      def wkt_spatial_query(wkt) do
        from(event in "events",
          where: contains(geom_from_text(^wkt), event.geom),
          select: event.id
        )
      end

      def ambiguous_query do
        from(event in "events",
          where: contains(event.region, event.geom),
          select: event.id
        )
      end
    end

    assert Query.text_query() |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."name" FROM "events" AS q0 WHERE contains(q0."name", 'duck')]

    assert Query.pinned_text_query("duck")
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT q0."name" FROM "events" AS q0 WHERE contains(q0."name", ?)]

    assert Query.json_text_query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE contains(json_extract_string(q0."payload", '$.name'), 'duck')]

    assert Query.spatial_query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE ST_Contains(ST_MakeEnvelope(0, 0, 10, 10), q0."geom")]

    assert Query.wkt_spatial_query("POINT (1 2)")
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE ST_Contains(ST_GeomFromText(?), q0."geom")]

    assert Query.ambiguous_query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE ST_Contains(q0."region", q0."geom")]
  end
end

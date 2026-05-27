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

      def spatial_query do
        from(event in "events",
          where: contains(envelope(0, 0, 10, 10), event.geom),
          select: event.id
        )
      end
    end

    assert Query.text_query() |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."name" FROM "events" AS q0 WHERE contains(q0."name", 'duck')]

    assert Query.spatial_query()
           |> Ecto.Adapters.QuackDB.Connection.all()
           |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE ST_Contains(ST_MakeEnvelope(0, 0, 10, 10), q0."geom")]
  end
end

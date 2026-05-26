defmodule QuackDB.Ecto.SQLGeneration.SpatialTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Spatial

  test "generates spatial fragments" do
    query =
      from(place in "places",
        where: intersects(place.geom, ^%Geo.Point{coordinates: {1.0, 2.0}, srid: nil}),
        select: %{
          point: point(1, 2),
          wkb: as_wkb(place.geom),
          hexwkb: as_hex_wkb(place.geom),
          wkt: as_text(place.geom),
          distance: distance(place.geom, ^%Geo.Point{coordinates: {3.0, 4.0}, srid: nil})
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~s|SELECT ST_Point(1, 2) AS "point", ST_AsWKB(q0."geom") AS "wkb", ST_AsHEXWKB(q0."geom") AS "hexwkb", ST_AsText(q0."geom") AS "wkt", ST_Distance(q0."geom", ?) AS "distance" FROM "places" AS q0 WHERE ST_Intersects(q0."geom", ?)|
  end
end

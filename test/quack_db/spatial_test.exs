defmodule QuackDB.SpatialTest do
  use ExUnit.Case, async: true

  alias QuackDB.Spatial

  test "builds spatial extension statements" do
    assert Spatial.install() |> IO.iodata_to_binary() == "INSTALL spatial;"
    assert Spatial.load() |> IO.iodata_to_binary() == "LOAD spatial;"
  end

  test "builds spatial SQL expressions" do
    point = Spatial.point(1, 2)

    assert IO.iodata_to_binary(point) == "ST_Point(1, 2)"
    assert Spatial.as_wkb(point) |> IO.iodata_to_binary() == "ST_AsWKB(ST_Point(1, 2))"
    assert Spatial.as_hex_wkb(point) |> IO.iodata_to_binary() == "ST_AsHEXWKB(ST_Point(1, 2))"
    assert Spatial.as_text(point) |> IO.iodata_to_binary() == "ST_AsText(ST_Point(1, 2))"
  end

  test "builds geometry constructors" do
    assert Spatial.geom_from_wkb(<<1, 2, 3>>) |> IO.iodata_to_binary() ==
             "ST_GeomFromWKB(from_hex('010203'))"

    assert Spatial.geom_from_text("POINT (1 2)") |> IO.iodata_to_binary() ==
             "ST_GeomFromText('POINT (1 2)')"
  end
end

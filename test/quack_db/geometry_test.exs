if Code.ensure_loaded?(Geo.WKB) do
  defmodule QuackDB.GeometryTest do
    use ExUnit.Case, async: true

    test "decodes and encodes WKB-compatible geometry bytes" do
      wkb = Base.decode16!("0101000000000000000000F03F0000000000000040", case: :mixed)

      assert %Geo.Point{coordinates: {1.0, 2.0}} = QuackDB.Geometry.decode_wkb!(wkb)
      assert %Geo.Point{coordinates: {1.0, 2.0}} = QuackDB.Geometry.to_geo!(wkb)
      assert QuackDB.Geometry.encode_wkb!(%Geo.Point{coordinates: {1.0, 2.0}, srid: nil}) == wkb
      assert QuackDB.Geometry.from_geo!(%Geo.Point{coordinates: {1.0, 2.0}, srid: nil}) == wkb
    end
  end
end

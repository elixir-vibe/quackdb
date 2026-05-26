if Code.ensure_loaded?(Geo.WKB) do
  defmodule QuackDB.GeoTest do
    use ExUnit.Case, async: true

    test "decodes and encodes WKB-compatible geometry bytes" do
      wkb = Base.decode16!("0101000000000000000000F03F0000000000000040", case: :mixed)

      assert %Geo.Point{coordinates: {1.0, 2.0}} = QuackDB.Geo.decode_wkb!(wkb)
      assert QuackDB.Geo.encode_wkb!(%Geo.Point{coordinates: {1.0, 2.0}, srid: nil}) == wkb
    end
  end
end

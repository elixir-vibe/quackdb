defmodule QuackDB.Spatial do
  @moduledoc """
  SQL helpers for DuckDB's spatial extension.

  These helpers return iodata fragments for raw DuckDB SQL. Load the spatial
  extension before using `ST_*` functions:

      QuackDB.query!(conn, QuackDB.Spatial.load())

  Geometry values returned by DuckDB's Quack protocol decode as WKB-compatible
  binaries.
  """

  @doc "Builds an `INSTALL spatial;` statement."
  @spec install() :: iodata()
  def install, do: QuackDB.SQL.install(:spatial)

  @doc "Builds a `LOAD spatial;` statement."
  @spec load() :: iodata()
  def load, do: QuackDB.SQL.load(:spatial)

  @doc "Builds `ST_Point(x, y)`."
  @spec point(number(), number()) :: iodata()
  def point(x, y), do: call("ST_Point", [literal!(x), literal!(y)])

  @doc "Builds `ST_AsWKB(geometry)`."
  @spec as_wkb(iodata()) :: iodata()
  def as_wkb(geometry), do: call("ST_AsWKB", [geometry])

  @doc "Builds `ST_AsHEXWKB(geometry)`."
  @spec as_hex_wkb(iodata()) :: iodata()
  def as_hex_wkb(geometry), do: call("ST_AsHEXWKB", [geometry])

  @doc "Builds `ST_AsText(geometry)`."
  @spec as_text(iodata()) :: iodata()
  def as_text(geometry), do: call("ST_AsText", [geometry])

  @doc "Builds `ST_AsGeoJSON(geometry)`."
  @spec as_geojson(iodata()) :: iodata()
  def as_geojson(geometry), do: call("ST_AsGeoJSON", [geometry])

  @doc "Builds `ST_Intersects(left, right)`."
  @spec intersects(iodata(), iodata()) :: iodata()
  def intersects(left, right), do: call("ST_Intersects", [left, right])

  @doc "Builds `ST_MakeEnvelope(min_x, min_y, max_x, max_y)`."
  @spec envelope(number(), number(), number(), number()) :: iodata()
  def envelope(min_x, min_y, max_x, max_y) do
    call("ST_MakeEnvelope", [literal!(min_x), literal!(min_y), literal!(max_x), literal!(max_y)])
  end

  @doc "Builds `ST_GeomFromWKB(wkb)`."
  @spec geom_from_wkb(binary() | iodata()) :: iodata()
  def geom_from_wkb(wkb) when is_binary(wkb), do: call("ST_GeomFromWKB", [literal!({:blob, wkb})])
  def geom_from_wkb(wkb), do: call("ST_GeomFromWKB", [wkb])

  @doc "Builds `ST_GeomFromText(wkt)`."
  @spec geom_from_text(String.t()) :: iodata()
  def geom_from_text(wkt) when is_binary(wkt), do: call("ST_GeomFromText", [literal!(wkt)])

  defp call(function, args) do
    [function, "(", Enum.intersperse(args, ", "), ")"]
  end

  defp literal!(value) do
    case QuackDB.SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, error} -> raise error
    end
  end
end

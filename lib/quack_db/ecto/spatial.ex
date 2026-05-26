if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Spatial do
    @moduledoc """
    DuckDB spatial expression helpers for Ecto queries.

    These macros wrap DuckDB spatial `ST_*` functions in Ecto fragments. Load
    DuckDB's spatial extension before executing queries that use these helpers.
    Pinned `%Geo.*{}` values are supported when the optional `:geo` package is
    available.
    """

    defmacro point(x, y) do
      quote do
        fragment("ST_Point(?, ?)", unquote(x), unquote(y))
      end
    end

    defmacro as_wkb(geometry) do
      quote do
        fragment("ST_AsWKB(?)", unquote(geometry))
      end
    end

    defmacro as_hex_wkb(geometry) do
      quote do
        fragment("ST_AsHEXWKB(?)", unquote(geometry))
      end
    end

    defmacro as_text(geometry) do
      quote do
        fragment("ST_AsText(?)", unquote(geometry))
      end
    end

    defmacro as_geojson(geometry) do
      quote do
        fragment("ST_AsGeoJSON(?)", unquote(geometry))
      end
    end

    defmacro envelope(min_x, min_y, max_x, max_y) do
      quote do
        fragment(
          "ST_MakeEnvelope(?, ?, ?, ?)",
          unquote(min_x),
          unquote(min_y),
          unquote(max_x),
          unquote(max_y)
        )
      end
    end

    defmacro geom_from_wkb(wkb) do
      quote do
        fragment("ST_GeomFromWKB(?)", unquote(wkb))
      end
    end

    defmacro geom_from_text(wkt) do
      quote do
        fragment("ST_GeomFromText(?)", unquote(wkt))
      end
    end

    defmacro intersects(left, right) do
      quote do
        fragment("ST_Intersects(?, ?)", unquote(left), unquote(right))
      end
    end

    defmacro contains(left, right) do
      quote do
        fragment("ST_Contains(?, ?)", unquote(left), unquote(right))
      end
    end

    defmacro distance(left, right) do
      quote do
        fragment("ST_Distance(?, ?)", unquote(left), unquote(right))
      end
    end
  end
end

defmodule QuackDB.Geometry do
  @moduledoc """
  Helpers for DuckDB spatial `GEOMETRY` values.

  DuckDB `GEOMETRY` values decode from Quack as WKB-compatible binaries. When
  the optional `:geo` package is installed, this module can convert those
  binaries to and from `Geo` structs.
  """

  if Code.ensure_loaded?(Geo.WKB) do
    @doc "Decodes WKB-compatible geometry bytes into a `Geo` struct."
    @spec decode_wkb(binary()) :: {:ok, struct()} | {:error, term()}
    def decode_wkb(wkb) when is_binary(wkb) do
      wkb
      |> Base.encode16(case: :upper)
      |> Geo.WKB.decode()
    end

    @doc "Decodes WKB-compatible geometry bytes into a `Geo` struct or raises."
    @spec decode_wkb!(binary()) :: struct()
    def decode_wkb!(wkb) when is_binary(wkb) do
      wkb
      |> Base.encode16(case: :upper)
      |> Geo.WKB.decode!()
    end

    @doc "Alias for `decode_wkb/1`."
    @spec to_geo(binary()) :: {:ok, struct()} | {:error, term()}
    def to_geo(wkb), do: decode_wkb(wkb)

    @doc "Alias for `decode_wkb!/1`."
    @spec to_geo!(binary()) :: struct()
    def to_geo!(wkb), do: decode_wkb!(wkb)

    @doc "Encodes a `Geo` struct into WKB bytes accepted by DuckDB spatial functions."
    @spec encode_wkb!(struct()) :: binary()
    def encode_wkb!(geometry) do
      geometry
      |> Geo.WKB.encode!(:ndr)
      |> Base.decode16!(case: :mixed)
    end

    @doc "Alias for `encode_wkb!/1`."
    @spec from_geo!(struct()) :: binary()
    def from_geo!(geometry), do: encode_wkb!(geometry)
  end
end

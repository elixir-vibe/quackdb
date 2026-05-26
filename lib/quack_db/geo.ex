if Code.ensure_loaded?(Geo.WKB) do
  defmodule QuackDB.Geo do
    @moduledoc """
    Optional bridge between QuackDB geometry bytes and `Geo` structs.

    DuckDB spatial `GEOMETRY` values decode as WKB-compatible bytes. This module
    is available when the optional `:geo` package is installed.
    """

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

    @doc "Encodes a `Geo` struct into WKB bytes accepted by DuckDB spatial functions."
    @spec encode_wkb!(struct()) :: binary()
    def encode_wkb!(geometry) do
      geometry
      |> Geo.WKB.encode!(:ndr)
      |> Base.decode16!(case: :mixed)
    end
  end
end

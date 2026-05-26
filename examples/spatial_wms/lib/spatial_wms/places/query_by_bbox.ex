defmodule SpatialWMS.Places.QueryByBBox do
  @moduledoc false

  use Ash.Resource.ManualRead

  import Ecto.Query
  import QuackDB.Ecto.Spatial, only: [as_wkb: 1, envelope: 4, intersects: 2]

  alias Ash.Query
  alias SpatialWMS.Places.Place
  alias SpatialWMS.Repo

  @table "wms_places"

  @impl true
  def read(ash_query, _data_layer_query, _opts, _context) do
    {:ok, bbox} = Query.fetch_argument(ash_query, :bbox)
    rows = read_places(bbox)
    {:ok, Enum.map(rows, &place/1)}
  end

  defp read_places({min_x, min_y, max_x, max_y}) do
    query =
      from(place in @table,
        where: intersects(place.geom, envelope(^min_x, ^min_y, ^max_x, ^max_y)),
        order_by: place.id,
        select: %{id: place.id, name: place.name, geometry: as_wkb(place.geom)}
      )

    Repo.all(query)
  end

  defp place(row) do
    %Place{
      id: row.id,
      name: row.name,
      geometry: row.geometry |> Geo.WKB.decode!() |> Geo.JSON.encode!()
    }
  end
end

defmodule SpatialWMS.Places do
  use Ash.Domain

  import Ecto.Query
  import QuackDB.Ecto.Spatial, only: [as_geojson: 1, envelope: 4, intersects: 2]

  alias QuackDB.Spatial
  alias SpatialWMS.Places.Place
  alias SpatialWMS.Repo

  @layer "places"
  @table "wms_places"

  resources do
    resource(Place)
  end

  def layer, do: @layer

  def init! do
    Repo.query!(Spatial.load())

    Repo.query!(QuackDB.DDL.drop_table(@table, if_exists: true))

    Repo.query!(
      QuackDB.DDL.create_table(@table, [id: :integer, name: :varchar, geom: :geometry],
        temporary: true
      )
    )

    seed_places()
    |> Enum.map(fn {id, name, {lon, lat}} ->
      [id: id, name: name, geom: {:expr, Spatial.point(lon, lat)}]
    end)
    |> then(&Repo.query!(QuackDB.DML.insert_into(@table, &1)))
  end

  def by_bbox({min_x, min_y, max_x, max_y}) do
    query =
      from(place in @table,
        where: intersects(place.geom, envelope(^min_x, ^min_y, ^max_x, ^max_y)),
        order_by: place.id,
        select: %{id: place.id, name: place.name, geometry: as_geojson(place.geom)}
      )

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      Place
      |> Ash.Changeset.for_create(:new, %{
        id: row.id,
        name: row.name,
        geometry: Jason.decode!(row.geometry)
      })
      |> Ash.create!()
    end)
  end

  defp seed_places do
    [
      {1, "São Paulo", {-46.6333, -23.5505}},
      {2, "London", {-0.1276, 51.5072}},
      {3, "Tokyo", {139.6917, 35.6895}},
      {4, "New York", {-74.0060, 40.7128}},
      {5, "Cape Town", {18.4241, -33.9249}}
    ]
  end
end

defmodule SpatialWMS.Places.DuckDB do
  @moduledoc false

  import Ecto.Query
  import QuackDB.Ecto.Spatial, only: [as_wkb: 1, envelope: 4, intersects: 2]

  alias Ecto.Migrator
  alias QuackDB.{DDL, Spatial}
  alias SpatialWMS.Places
  alias SpatialWMS.Places.Seeds
  alias SpatialWMS.Repo
  alias SpatialWMS.Repo.Migrations.CreatePlaces

  @migration_version 20_260_526_000_001
  @table "wms_places"

  def setup! do
    Repo.query!(Spatial.load())
    Repo.query!(DDL.drop_table(@table, if_exists: true))
    Repo.query!(DDL.drop_table("schema_migrations", if_exists: true))
    Migrator.up(Repo, @migration_version, CreatePlaces, log: false)
    Seeds.load!()
  end

  def by_bbox({min_x, min_y, max_x, max_y}) do
    query =
      from(place in @table,
        where: intersects(place.geom, envelope(^min_x, ^min_y, ^max_x, ^max_y)),
        order_by: place.id,
        select: %{id: place.id, name: place.name, geometry: as_wkb(place.geom)}
      )

    query
    |> Repo.all()
    |> Enum.map(&place!/1)
  end

  defp place!(row) do
    Places.place!(%{
      id: row.id,
      name: row.name,
      geometry: row.geometry |> Geo.WKB.decode!() |> Geo.JSON.encode!()
    })
  end
end

defmodule SpatialWMS.Places.DuckDB do
  @moduledoc false

  alias Ecto.Migrator
  alias QuackDB.Spatial
  alias SpatialWMS.Places.Seeds
  alias SpatialWMS.Repo
  alias SpatialWMS.Repo.Migrations.CreatePlaces

  @migration_version 20_260_526_000_001

  def setup! do
    Repo.query!(Spatial.load())
    Migrator.up(Repo, @migration_version, CreatePlaces, log: false)
    Seeds.reset!()
  end
end

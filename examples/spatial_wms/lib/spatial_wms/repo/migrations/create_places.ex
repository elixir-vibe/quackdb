defmodule SpatialWMS.Repo.Migrations.CreatePlaces do
  @moduledoc false

  use Ecto.Migration

  def change do
    create table(:wms_places, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:name, :string, null: false)
      add(:geom, :geometry, null: false)
    end
  end
end

defmodule SpatialWMS.Places.Place do
  use Ash.Resource,
    domain: SpatialWMS.Places,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:geometry, :map, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :new do
      accept([:id, :name, :geometry])
    end
  end
end

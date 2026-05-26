defmodule SpatialWMS.Places.Place do
  use Ash.Resource,
    domain: SpatialWMS.Places

  actions do
    read :by_bbox do
      argument(:bbox, :tuple,
        allow_nil?: false,
        constraints: [
          fields: [
            min_x: [type: :float, allow_nil?: false],
            min_y: [type: :float, allow_nil?: false],
            max_x: [type: :float, allow_nil?: false],
            max_y: [type: :float, allow_nil?: false]
          ]
        ]
      )

      manual(SpatialWMS.Places.QueryByBBox)
    end
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:geometry, :map, allow_nil?: false, public?: true)
  end
end

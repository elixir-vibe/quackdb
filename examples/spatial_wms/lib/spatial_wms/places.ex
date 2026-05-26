defmodule SpatialWMS.Places do
  use Ash.Domain

  alias SpatialWMS.Places.Place

  @layer "places"

  resources do
    resource Place do
      define(:by_bbox, args: [:bbox])
    end
  end

  def layer, do: @layer
end

defmodule SpatialWMS.Places do
  use Ash.Domain

  alias SpatialWMS.Places.Place

  @layer "places"

  resources do
    resource Place do
      define(:place, action: :new)
    end
  end

  def layer, do: @layer
end

defmodule SpatialWMS.Web.GeoJSON do
  @moduledoc false

  def feature_collection(places) do
    %{type: "FeatureCollection", features: Enum.map(places, &feature/1)}
  end

  defp feature(place) do
    %{
      type: "Feature",
      id: place.id,
      properties: %{name: place.name},
      geometry: place.geometry
    }
  end
end

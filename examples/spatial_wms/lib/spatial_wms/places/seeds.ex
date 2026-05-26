defmodule SpatialWMS.Places.Seeds do
  @moduledoc false

  alias QuackDB.{DML, Spatial}
  alias SpatialWMS.Repo

  @table "wms_places"

  def reset! do
    Repo.delete_all(@table)
    load!()
  end

  def load! do
    @table
    |> DML.insert_into(seed_rows())
    |> Repo.query!()
  end

  defp seed_rows do
    Enum.map(seed_places(), fn {id, name, {lon, lat}} ->
      [id: id, name: name, geom: {:expr, Spatial.point(lon, lat)}]
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

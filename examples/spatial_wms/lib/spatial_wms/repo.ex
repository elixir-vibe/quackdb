defmodule SpatialWms.Repo do
  use Ecto.Repo,
    otp_app: :spatial_wms,
    adapter: Ecto.Adapters.QuackDB
end

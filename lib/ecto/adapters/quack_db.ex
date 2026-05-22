defmodule Ecto.Adapters.QuackDB do
  @moduledoc """
  Minimal Ecto SQL adapter for QuackDB.

  The first Ecto milestone intentionally supports raw SQL through
  `Ecto.Adapters.SQL.query/4` and repository `query/3` helpers only. Schema
  query generation, migrations, storage callbacks, and write planning are not
  implemented yet.

  ## Configuration

      config :my_app, MyApp.AnalyticsRepo,
        adapter: Ecto.Adapters.QuackDB,
        uri: "http://[::1]:9494",
        token: "super_secret"

  """

  use Ecto.Adapters.SQL,
    driver: :quackdb

  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction?, do: true

  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _options, _fun) do
    unsupported!(
      :migrations,
      "Ecto migrations are not supported yet; use Repo.query/3 for raw SQL"
    )
  end

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

  defp unsupported!(feature, message) do
    raise QuackDB.Error.new(:ecto_feature_not_supported, message,
            source: :client,
            metadata: %{feature: feature}
          )
  end
end

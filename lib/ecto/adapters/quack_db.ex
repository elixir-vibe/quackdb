if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ecto.Adapters.QuackDB do
    @moduledoc """
    Minimal Ecto SQL adapter for QuackDB.

    Ecto SQL adapter for DuckDB over QuackDB. Supports raw SQL, analytical query
    generation, insert paths, common mutations, and basic migration DDL.

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
    def lock_for_migrations(_meta, _options, fun), do: fun.()

    @impl Ecto.Adapter.Schema
    def autogenerate(:id), do: nil
    def autogenerate(:embed_id), do: Ecto.UUID.generate()
    def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

    def loaders({:map, _}, type), do: [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
    def loaders(:map, type), do: [&json_decode/1, type]
    def loaders(:binary_id, type), do: [Ecto.UUID, type]
    def loaders(_, type), do: [type]

    def dumpers({:map, _}, type), do: [&Ecto.Type.embedded_dump(type, &1, :json)]
    def dumpers(:binary_id, type), do: [type, Ecto.UUID]
    def dumpers(_, type), do: [type]

    @impl Ecto.Adapter.Schema
    def insert_all(
          adapter_meta,
          schema_meta,
          header,
          rows,
          on_conflict,
          returning,
          placeholders,
          opts
        ) do
      case Keyword.get(opts, :insert_method, :sql) do
        :sql ->
          sql_insert_all(
            adapter_meta,
            schema_meta,
            header,
            rows,
            on_conflict,
            returning,
            placeholders,
            opts
          )

        :append ->
          Ecto.Adapters.QuackDB.AppendInsert.run(
            adapter_meta,
            schema_meta,
            header,
            rows,
            on_conflict,
            returning,
            placeholders,
            opts
          )

        other ->
          unsupported!(
            :schema_inserts,
            "unsupported insert_method for QuackDB: #{inspect(other)}"
          )
      end
    end

    defp sql_insert_all(
           adapter_meta,
           schema_meta,
           header,
           rows,
           on_conflict,
           returning,
           placeholders,
           opts
         ) do
      Ecto.Adapters.SQL.insert_all(
        adapter_meta,
        schema_meta,
        @conn,
        header,
        rows,
        on_conflict,
        returning,
        placeholders,
        opts
      )
    end

    defp json_decode(value) when is_binary(value), do: JSON.decode(value)
    defp json_decode(value), do: {:ok, value}

    defp unsupported!(feature, message) do
      raise QuackDB.Error.new(:ecto_feature_not_supported, message,
              source: :client,
              metadata: %{feature: feature}
            )
    end
  end
end

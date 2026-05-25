if Code.ensure_loaded?(Ecto.Adapters.SQL) do
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

        :append ->
          append_insert_all(
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

    defp append_insert_all(
           adapter_meta,
           schema_meta,
           header,
           rows,
           on_conflict,
           returning,
           placeholders,
           opts
         ) do
      with :ok <- assert_append_insert_all!(rows, on_conflict, returning, placeholders),
           conn <- ecto_connection(adapter_meta),
           insert_rows <- ecto_append_rows(header, rows),
           options <- ecto_append_options(schema_meta, opts),
           {:ok, %QuackDB.Result{} = result} <-
             QuackDB.insert_rows(conn, schema_meta.source, insert_rows, options) do
        {result.num_rows, nil}
      else
        {:error, %QuackDB.Error{} = error} -> raise error
      end
    end

    defp assert_append_insert_all!(%Ecto.Query{}, _on_conflict, _returning, _placeholders) do
      unsupported!(
        :schema_inserts,
        "insert_method: :append does not support insert_all from queries"
      )
    end

    defp assert_append_insert_all!(_rows, {_kind, _params, targets}, _returning, _placeholders)
         when targets != [] do
      unsupported!(:schema_inserts, "insert_method: :append does not support conflict targets")
    end

    defp assert_append_insert_all!(_rows, {:raise, _params, []}, [], []), do: :ok

    defp assert_append_insert_all!(_rows, _on_conflict, _returning, _placeholders) do
      unsupported!(
        :schema_inserts,
        "insert_method: :append only supports plain insert_all without returning, placeholders, or upserts"
      )
    end

    defp ecto_connection(%{pid: pool} = adapter_meta) do
      case Process.get({Ecto.Adapters.SQL, pool}) do
        :undefined -> ecto_pool(adapter_meta)
        nil -> ecto_pool(adapter_meta)
        conn -> conn
      end
    end

    defp ecto_pool(%{partition_supervisor: {name, _}}),
      do: {:via, PartitionSupervisor, {name, self()}}

    defp ecto_pool(%{pid: pool}), do: pool

    defp ecto_append_rows(header, rows) do
      Enum.map(rows, fn row ->
        Enum.map(header, fn field -> {field, Keyword.fetch!(row, field)} end)
      end)
    end

    defp ecto_append_options(%{prefix: nil}, opts), do: append_options(opts)

    defp ecto_append_options(%{prefix: prefix}, opts) do
      opts
      |> append_options()
      |> Keyword.put(:schema, prefix)
    end

    defp append_options(opts) do
      opts
      |> Keyword.take([:timeout])
      |> maybe_put_batch_size(opts)
    end

    defp maybe_put_batch_size(options, opts) do
      case Keyword.fetch(opts, :chunk_every) do
        {:ok, chunk_every} -> Keyword.put(options, :batch_size, chunk_every)
        :error -> options
      end
    end

    defp unsupported!(feature, message) do
      raise QuackDB.Error.new(:ecto_feature_not_supported, message,
              source: :client,
              metadata: %{feature: feature}
            )
    end
  end
end

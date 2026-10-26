if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ecto.Adapters.QuackDB.AppendInsert do
    @moduledoc false

    # Native appends stream rows into `INSERT INTO ... SELECT * FROM
    # scan_data_from_quack_client(...)`, so the INSERT names its columns and
    # carries ON CONFLICT and RETURNING itself.
    def run(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders, opts) do
      with :ok <- assert_supported!(rows, on_conflict, placeholders),
           conn <- ecto_connection(adapter_meta),
           options <- append_options(schema_meta, header, on_conflict, returning, opts),
           {:ok, %QuackDB.Result{} = result} <-
             insert_all(conn, schema_meta, header, rows, options) do
        {result.num_rows, result.rows}
      else
        {:error, %QuackDB.Error{} = error} -> raise error
      end
    end

    defp insert_all(conn, schema_meta, header, rows, options) do
      case Keyword.get(options, :append_shape, :columns) do
        :columns ->
          columns = append_columns(header, rows, options)
          QuackDB.insert_columns(conn, schema_meta.source, columns, options)

        :rows ->
          rows = append_rows(header, rows, options)
          QuackDB.insert_rows(conn, schema_meta.source, rows, options)
      end
    end

    defp column_type!(columns, column) do
      Enum.find_value(columns, fn
        {^column, type} ->
          {:ok, type}

        {name, type} when is_atom(name) and is_binary(column) ->
          if Atom.to_string(name) == column, do: {:ok, type}

        {name, type} when is_binary(name) and is_atom(column) ->
          if name == Atom.to_string(column), do: {:ok, type}

        _entry ->
          nil
      end)
      |> case do
        {:ok, type} -> type
        nil -> raise KeyError, key: column, term: columns
      end
    end

    defp dml_on_conflict({:raise, _params, []}), do: :raise
    defp dml_on_conflict({:nothing, _params, []}), do: :nothing
    defp dml_on_conflict({:nothing, _params, targets}), do: {:nothing, targets}

    defp assert_supported!({%Ecto.Query{}, _params}, _on_conflict, _placeholders),
      do:
        unsupported!(
          :schema_inserts,
          "insert_method: :append does not support insert_all from queries"
        )

    defp assert_supported!(%Ecto.Query{}, _on_conflict, _placeholders),
      do:
        unsupported!(
          :schema_inserts,
          "insert_method: :append does not support insert_all from queries"
        )

    defp assert_supported!(_rows, _on_conflict, placeholders) when placeholders != [],
      do: unsupported!(:schema_inserts, "insert_method: :append does not support placeholders")

    defp assert_supported!(_rows, {conflict, _params, _targets}, _placeholders)
         when conflict in [:raise, :nothing],
         do: :ok

    defp assert_supported!(_rows, _on_conflict, _placeholders) do
      unsupported!(
        :schema_inserts,
        "insert_method: :append only supports on_conflict: :raise or :nothing"
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

    defp append_rows(header, rows, options) do
      column_types = Enum.map(header, &column_type(Keyword.get(options, :columns, []), &1))

      Enum.map(rows, fn row ->
        case ordered_row_entries(row, header, column_types, []) do
          {:ok, entries} -> entries
          :error -> fetched_row_entries(row, header, column_types)
        end
      end)
    end

    defp ordered_row_entries([], [], [], entries), do: {:ok, Enum.reverse(entries)}

    defp ordered_row_entries(
           [{field, value} | row],
           [field | header],
           [type | column_types],
           entries
         ) do
      entry = {field, normalize_append_value(value, type)}
      ordered_row_entries(row, header, column_types, [entry | entries])
    end

    defp ordered_row_entries(_row, _header, _column_types, _entries), do: :error

    defp fetched_row_entries(row, header, column_types) do
      header
      |> Enum.zip(column_types)
      |> Enum.map(fn {field, type} ->
        {field, row |> Keyword.fetch!(field) |> normalize_append_value(type)}
      end)
    end

    defp append_columns(header, rows, options) do
      column_types = Enum.map(header, &column_type(Keyword.get(options, :columns, []), &1))
      accumulators = Enum.map(header, fn _field -> [] end)

      rows
      |> Enum.reduce(accumulators, fn row, accumulators ->
        row
        |> append_row_values(header, column_types)
        |> prepend_column_values(accumulators)
      end)
      |> then(fn columns ->
        header
        |> Enum.zip(columns)
        |> Enum.map(fn {field, values} -> {field, Enum.reverse(values)} end)
      end)
    end

    defp append_row_values(row, header, column_types) do
      case ordered_row_values(row, header, column_types, []) do
        {:ok, values} -> values
        :error -> fetched_row_values(row, header, column_types)
      end
    end

    defp ordered_row_values([], [], [], values), do: {:ok, Enum.reverse(values)}

    defp ordered_row_values(
           [{field, value} | row],
           [field | header],
           [type | column_types],
           values
         ) do
      ordered_row_values(row, header, column_types, [normalize_append_value(value, type) | values])
    end

    defp ordered_row_values(_row, _header, _column_types, _values), do: :error

    defp fetched_row_values(row, header, column_types) do
      header
      |> Enum.zip(column_types)
      |> Enum.map(fn {field, type} ->
        row |> Keyword.fetch!(field) |> normalize_append_value(type)
      end)
    end

    defp prepend_column_values(values, accumulators) do
      values
      |> Enum.zip(accumulators)
      |> Enum.map(fn {value, accumulator} -> [value | accumulator] end)
    end

    defp normalize_append_value(nil, _type), do: nil
    defp normalize_append_value({:blob, value}, :blob), do: value

    # The adapter dumps UUIDs tagged with their canonical string; the append
    # path wants the bytes.
    defp normalize_append_value({:uuid, value}, :uuid),
      do: normalize_append_value(Ecto.UUID.dump!(value), :uuid)

    # Ecto dumps UUIDs as network-order bytes. DuckDB stores a signed int128
    # with the top bit flipped to preserve UUID ordering.
    defp normalize_append_value(<<value::unsigned-big-128>>, :uuid),
      do: value - 0x80000000000000000000000000000000

    defp normalize_append_value(values, {:list, type}) when is_list(values) do
      Enum.map(values, &normalize_append_value(&1, type))
    end

    defp normalize_append_value({:json, value}, :varchar) when is_binary(value), do: value
    defp normalize_append_value({:json, value}, :varchar), do: JSON.encode!(value)

    defp normalize_append_value(value, :varchar) when is_map(value) and not is_struct(value) do
      JSON.encode!(value)
    end

    defp normalize_append_value(value, _type), do: value

    defp column_type(columns, column) do
      case column_type!(columns, column) do
        {:json, _type} -> :varchar
        type -> type
      end
    rescue
      KeyError -> nil
    end

    defp append_options(schema_meta, header, on_conflict, returning, opts) do
      opts =
        opts
        |> base_options()
        |> maybe_put_schema(schema_meta)
        |> Keyword.put(:on_conflict, dml_on_conflict(on_conflict))
        |> Keyword.put(:returning, returning)

      case Keyword.fetch(opts, :columns) do
        {:ok, _columns} -> opts
        :error -> maybe_put_schema_columns(opts, schema_meta, header)
      end
    end

    defp maybe_put_schema(opts, %{prefix: nil}), do: opts

    # A dotted prefix names a nested schema path, as in Ecto reads.
    defp maybe_put_schema(opts, %{prefix: prefix}),
      do: Keyword.put(opts, :schema, prefix |> to_string() |> String.split("."))

    defp maybe_put_schema_columns(opts, %{schema: nil}, _header), do: opts

    defp maybe_put_schema_columns(opts, %{schema: schema}, header) do
      source_types =
        Map.new(schema.__schema__(:fields), fn field ->
          {schema.__schema__(:field_source, field),
           QuackDB.Ecto.Type.column_type!(schema.__schema__(:type, field), :append)}
        end)

      columns = Enum.map(header, fn source -> {source, Map.fetch!(source_types, source)} end)
      Keyword.put(opts, :columns, columns)
    end

    defp base_options(opts) do
      opts
      |> Keyword.take([:timeout, :columns, :append_shape])
      |> validate_append_shape!()
      |> maybe_put_batch_size(opts)
    end

    defp validate_append_shape!(options) do
      case Keyword.get(options, :append_shape, :columns) do
        shape when shape in [:columns, :rows] ->
          options

        other ->
          unsupported!(
            :schema_inserts,
            "unsupported append_shape for QuackDB append insert: #{inspect(other)}"
          )
      end
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

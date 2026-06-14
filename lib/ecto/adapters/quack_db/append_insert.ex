if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ecto.Adapters.QuackDB.AppendInsert do
    @moduledoc false

    import QuackDB.SQL.Fragment, only: [table: 1]

    def run(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders, opts) do
      with :ok <- assert_supported!(schema_meta, rows, on_conflict, returning, placeholders, opts),
           conn <- ecto_connection(adapter_meta),
           append_header <- append_header(schema_meta, header),
           options <- append_options(schema_meta, append_header, opts),
           {:ok, %QuackDB.Result{} = result} <-
             insert_all(conn, schema_meta, append_header, rows, on_conflict, returning, options) do
        {result.num_rows, result.rows}
      else
        {:error, %QuackDB.Error{} = error} -> raise error
      end
    end

    defp insert_all(conn, schema_meta, header, rows, on_conflict, returning, options) do
      if insert_select?(schema_meta, header, on_conflict, returning) do
        insert_select(conn, schema_meta, header, rows, on_conflict, returning, options)
      else
        direct_insert_all(conn, schema_meta, header, rows, options)
      end
    end

    defp direct_insert_all(conn, schema_meta, header, rows, options) do
      case Keyword.get(options, :append_shape, :columns) do
        :columns ->
          columns = append_columns(header, rows, options)
          QuackDB.insert_columns(conn, schema_meta.source, columns, options)

        :rows ->
          rows = append_rows(header, rows, options)
          QuackDB.insert_rows(conn, schema_meta.source, rows, options)
      end
    end

    defp insert_select?(_schema_meta, _header, _on_conflict, returning) when returning != [],
      do: true

    defp insert_select?(_schema_meta, _header, {:nothing, _params, _targets}, _returning),
      do: true

    defp insert_select?(%{schema: nil}, _header, _on_conflict, _returning), do: false

    defp insert_select?(schema_meta, header, _on_conflict, _returning) do
      MapSet.new(header) != MapSet.new(schema_source_order(schema_meta))
    end

    defp insert_select(conn, schema_meta, header, rows, on_conflict, returning, options) do
      case DBConnection.status(conn, options) do
        :idle ->
          DBConnection.transaction(
            conn,
            fn tx ->
              case do_insert_select(
                     tx,
                     schema_meta,
                     header,
                     rows,
                     on_conflict,
                     returning,
                     options
                   ) do
                {:ok, result} -> result
                {:error, error} -> DBConnection.rollback(tx, error)
              end
            end,
            options
          )

        _status ->
          do_insert_select(conn, schema_meta, header, rows, on_conflict, returning, options)
      end
    end

    defp do_insert_select(conn, schema_meta, header, rows, on_conflict, returning, options) do
      temp_columns = append_columns!(schema_meta, header, options)
      temp_table = temp_table_name(temp_columns)
      create_statement = create_temp_table(temp_table, temp_columns)
      clear_statement = clear_temp_table(temp_table)

      insert_statement =
        insert_from_temp_statement(schema_meta, temp_columns, temp_table, on_conflict, returning)

      try do
        with {:ok, _result} <- QuackDB.query(conn, create_statement, [], options),
             {:ok, _result} <- QuackDB.query(conn, clear_statement, [], options),
             {:ok, _result} <- append_temp_data(conn, temp_table, header, rows, options),
             {:ok, %QuackDB.Result{} = result} <-
               QuackDB.query(conn, insert_statement, [], options) do
          {:ok, result}
        end
      after
        _ = QuackDB.query(conn, clear_statement, [], options)
      end
    end

    defp temp_table_name(columns) do
      hash = columns |> :erlang.phash2(4_294_967_296) |> Integer.to_string(36)
      "quackdb_append_#{hash}"
    end

    defp append_columns!(_schema_meta, header, options) do
      types = Keyword.fetch!(options, :columns)

      Enum.map(header, fn source ->
        %{
          source: source,
          type: column_type!(types, source)
        }
      end)
    end

    defp append_header(%{schema: nil}, header), do: header

    defp append_header(schema_meta, header) do
      schema_sources = schema_source_order(schema_meta)

      if MapSet.new(header) == MapSet.new(schema_sources), do: schema_sources, else: header
    end

    defp schema_source_order(%{schema: schema}) do
      Enum.map(schema.__schema__(:fields), &schema.__schema__(:field_source, &1))
    end

    defp create_temp_table(temp_table, columns) do
      ddl_columns = Enum.map(columns, fn column -> {column.source, column.type} end)
      QuackDB.DDL.create_table(temp_table, ddl_columns, temporary: true, if_not_exists: true)
    end

    defp clear_temp_table(temp_table) do
      ["DELETE FROM ", table(temp_table)]
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

    defp append_temp_data(conn, temp_table, header, rows, options) do
      case Keyword.get(options, :append_shape, :columns) do
        :columns ->
          columns = append_columns(header, rows, options)
          QuackDB.insert_columns(conn, temp_table, columns, options)

        :rows ->
          rows = append_rows(header, rows, options)
          QuackDB.insert_rows(conn, temp_table, rows, options)
      end
    end

    defp insert_from_temp_statement(schema_meta, columns, temp_table, on_conflict, returning) do
      header = Enum.map(columns, & &1.source)

      QuackDB.DML.insert_into_select(
        {schema_meta.prefix, schema_meta.source},
        header,
        temp_table,
        header,
        on_conflict: dml_on_conflict(on_conflict),
        returning: returning
      )
    end

    defp dml_on_conflict({:raise, _params, []}), do: :raise
    defp dml_on_conflict({:nothing, _params, []}), do: :nothing
    defp dml_on_conflict({:nothing, _params, targets}), do: {:nothing, targets}

    defp assert_supported!(
           _schema_meta,
           {%Ecto.Query{}, _params},
           _on_conflict,
           _returning,
           _placeholders,
           _opts
         ) do
      unsupported!(
        :schema_inserts,
        "insert_method: :append does not support insert_all from queries"
      )
    end

    defp assert_supported!(
           _schema_meta,
           %Ecto.Query{},
           _on_conflict,
           _returning,
           _placeholders,
           _opts
         ) do
      unsupported!(
        :schema_inserts,
        "insert_method: :append does not support insert_all from queries"
      )
    end

    defp assert_supported!(schema_meta, _rows, {:raise, _params, []}, returning, [], opts)
         when is_list(returning) do
      assert_insert_select_columns!(schema_meta, returning != [], opts, "returning")
    end

    defp assert_supported!(schema_meta, _rows, {:nothing, _params, _targets}, returning, [], opts)
         when is_list(returning) do
      assert_insert_select_columns!(schema_meta, true, opts, "on_conflict: :nothing")
    end

    defp assert_supported!(_schema_meta, _rows, _on_conflict, _returning, placeholders, _opts)
         when placeholders != [] do
      unsupported!(
        :schema_inserts,
        "insert_method: :append does not support placeholders"
      )
    end

    defp assert_supported!(_schema_meta, _rows, _on_conflict, _returning, _placeholders, _opts) do
      unsupported!(
        :schema_inserts,
        "insert_method: :append only supports plain insert_all or on_conflict: :nothing"
      )
    end

    defp assert_insert_select_columns!(_schema_meta, false, _opts, _feature), do: :ok

    defp assert_insert_select_columns!(schema_meta, true, opts, feature) do
      if schema_meta.schema != nil or Keyword.has_key?(opts, :columns) do
        :ok
      else
        unsupported!(
          :schema_inserts,
          "insert_method: :append with #{feature} requires a schema or explicit append columns"
        )
      end
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

    defp append_options(schema_meta, header, opts) do
      opts =
        opts
        |> base_options()
        |> maybe_put_schema(schema_meta)

      case Keyword.fetch(opts, :columns) do
        {:ok, _columns} -> opts
        :error -> maybe_put_schema_columns(opts, schema_meta, header)
      end
    end

    defp maybe_put_schema(opts, %{prefix: nil}), do: opts
    defp maybe_put_schema(opts, %{prefix: prefix}), do: Keyword.put(opts, :schema, prefix)

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

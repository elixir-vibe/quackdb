if Code.ensure_loaded?(Ecto.Adapters.SQL.Connection) do
  defmodule Ecto.Adapters.QuackDB.Connection do
    @moduledoc """
    Ecto SQL connection callbacks backed by the QuackDB DBConnection driver.

    This module implements the raw query path used by
    `Ecto.Adapters.SQL.query/4` and `Repo.query/3`, plus read-oriented Ecto
    query generation for analytical DuckDB queries. Unsupported query features
    raise explicit errors instead of emitting partial SQL.
    """

    @behaviour Ecto.Adapters.SQL.Connection

    alias Ecto.Migration.{Constraint, Index, Reference, Table}

    @impl true
    def child_spec(options) do
      {:ok, _} = Application.ensure_all_started(:db_connection)
      DBConnection.child_spec(QuackDB.DBConnection, options)
    end

    @impl true
    def prepare_execute(connection, name, statement, params, options) do
      ensure_list_params!(params)
      query = %QuackDB.Query{statement: IO.iodata_to_binary(statement)}

      case DBConnection.prepare_execute(
             connection,
             query,
             params,
             Keyword.put(options, :ecto_name, name)
           ) do
        {:ok, query, result} -> {:ok, query, normalize_result(result)}
        {:error, %QuackDB.Error{} = error} -> {:error, error}
        {:error, error} -> raise error
      end
    end

    @impl true
    def execute(connection, %QuackDB.Query{} = query, params, options) do
      ensure_list_params!(params)

      case DBConnection.execute(connection, query, params, options) do
        {:ok, query, result} -> {:ok, query, normalize_result(result)}
        {:error, %QuackDB.Error{} = error} -> {:error, error}
        {:error, error} -> raise error
      end
    end

    def execute(connection, statement, params, options)
        when is_binary(statement) or is_list(statement) do
      prepare_execute(connection, "", statement, dump_params(params), options)
    end

    @impl true
    def query(connection, statement, params, options) do
      ensure_list_params!(params)

      case prepare_execute(connection, "", statement, dump_params(params), options) do
        {:ok, _query, result} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    end

    @impl true
    def query_many(_connection, _statement, _params, _options) do
      unsupported!(:query_many, "multiple-result raw SQL is unsupported")
    end

    @impl true
    def stream(connection, statement, params, options) do
      ensure_list_params!(params)

      DBConnection.stream(connection, %QuackDB.Query{statement: statement}, params, options)
      |> Stream.map(&normalize_result/1)
    end

    @impl true
    def to_constraints(_exception, _options), do: []

    @impl true
    def all(%Ecto.Query{} = query), do: Ecto.Adapters.QuackDB.Query.all(query)

    @impl true
    def update_all(%Ecto.Query{} = query), do: Ecto.Adapters.QuackDB.Query.update_all(query)

    @impl true
    def delete_all(%Ecto.Query{} = query), do: Ecto.Adapters.QuackDB.Query.delete_all(query)

    if {:insert, 8} in Ecto.Adapters.SQL.Connection.behaviour_info(:callbacks) do
      def insert(prefix, table, header, rows, on_conflict, returning, placeholders) do
        insert(prefix, table, header, rows, on_conflict, returning, placeholders, [])
      end

      @impl true
      def insert(prefix, table, header, rows, on_conflict, returning, placeholders, _options) do
        insert_sql(prefix, table, header, rows, on_conflict, returning, placeholders)
      end
    else
      @impl true
      def insert(prefix, table, header, rows, on_conflict, returning, placeholders) do
        insert_sql(prefix, table, header, rows, on_conflict, returning, placeholders)
      end

      def insert(prefix, table, header, rows, on_conflict, returning, placeholders, _options) do
        insert_sql(prefix, table, header, rows, on_conflict, returning, placeholders)
      end
    end

    defp insert_sql(prefix, table, header, rows, on_conflict, returning, placeholders) do
      [
        "INSERT INTO ",
        quote_name(prefix, table),
        insert_columns(header),
        " ",
        insert_rows(rows),
        on_conflict(on_conflict),
        returning(returning, placeholders)
      ]
    end

    @impl true
    def update(prefix, table, fields, filters, returning) do
      [
        "UPDATE ",
        quote_name(prefix, table),
        " SET ",
        fields
        |> Enum.map(fn
          {field, _value} -> [quote_name(field), " = ?"]
          field -> [quote_name(field), " = ?"]
        end)
        |> Enum.intersperse(", "),
        " WHERE ",
        filters(filters),
        returning(returning, [])
      ]
    end

    @impl true
    def delete(prefix, table, filters, returning) do
      [
        "DELETE FROM ",
        quote_name(prefix, table),
        " WHERE ",
        filters(filters),
        returning(returning, [])
      ]
    end

    @impl true
    def explain_query(connection, query, params, options) do
      case query(connection, QuackDB.SQL.explain(query), params, options) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map_join(rows, "\n", &explain_row/1)}
        result -> result
      end
    end

    @impl true
    def execute_ddl({command, %Table{} = table, columns})
        when command in [:create, :create_if_not_exists] do
      assert_table_options!(table)

      serial_sequences = serial_sequence_ddl(command, table, columns)

      table_ddl = [
        "CREATE TABLE ",
        if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
        quote_name(table.prefix, table.name),
        " (",
        column_definitions(table, columns),
        pk_definition(columns, ", "),
        ")",
        table_options(table.options)
      ]

      [table_ddl | Enum.reverse(serial_sequences)] |> Enum.reverse()
    end

    def execute_ddl({command, %Table{} = table, _mode})
        when command in [:drop, :drop_if_exists] do
      [
        [
          "DROP TABLE ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_name(table.prefix, table.name)
        ]
      ]
    end

    def execute_ddl({:alter, %Table{} = table, changes}) do
      Enum.map(changes, fn change ->
        ["ALTER TABLE ", quote_name(table.prefix, table.name), " ", column_change(change)]
      end)
    end

    def execute_ddl({command, %Index{} = index})
        when command in [:create, :create_if_not_exists] do
      assert_index_options!(index)

      [
        [
          "CREATE ",
          if_do(index.unique, "UNIQUE "),
          "INDEX ",
          if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
          quote_name(index.name),
          " ON ",
          quote_name(index.prefix, index.table),
          " (",
          index.columns |> Enum.map(&index_expr/1) |> Enum.intersperse(", "),
          ")",
          if_do(index.where, [" WHERE ", to_string(index.where)])
        ]
      ]
    end

    def execute_ddl({command, %Constraint{} = constraint})
        when command in [:create, :create_if_not_exists] do
      assert_constraint_options!(constraint)

      if is_binary(constraint.check) do
        [
          [
            "ALTER TABLE ",
            quote_name(constraint.prefix, constraint.table),
            " ADD CONSTRAINT ",
            quote_name(constraint.name),
            " CHECK (",
            constraint.check,
            ")"
          ]
        ]
      else
        unsupported_iodata!(
          :migration_constraint,
          "DuckDB constraint DDL only supports check constraints"
        )
      end
    end

    def execute_ddl({command, %Constraint{} = constraint, _mode})
        when command in [:drop, :drop_if_exists] do
      [
        [
          "ALTER TABLE ",
          quote_name(constraint.prefix, constraint.table),
          " DROP CONSTRAINT ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_name(constraint.name)
        ]
      ]
    end

    def execute_ddl({command, %Index{} = index}) when command in [:drop, :drop_if_exists] do
      assert_index_drop_options!(index)

      [
        [
          "DROP INDEX ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_name(index.name)
        ]
      ]
    end

    def execute_ddl({command, %Index{} = index, _mode})
        when command in [:drop, :drop_if_exists] do
      execute_ddl({command, index})
    end

    def execute_ddl({:rename, %Table{} = table, %Table{} = new_table}) do
      [
        [
          "ALTER TABLE ",
          quote_name(table.prefix, table.name),
          " RENAME TO ",
          quote_name(new_table.name)
        ]
      ]
    end

    def execute_ddl({:rename, %Table{} = table, old_column, new_column}) do
      [
        [
          "ALTER TABLE ",
          quote_name(table.prefix, table.name),
          " RENAME COLUMN ",
          quote_name(old_column),
          " TO ",
          quote_name(new_column)
        ]
      ]
    end

    def execute_ddl(statement) when is_binary(statement), do: [statement]

    defp assert_table_options!(%Table{} = table) do
      cond do
        table.comment ->
          unsupported_iodata!(:migration_table, "DuckDB does not support table comments")

        table.engine ->
          unsupported_iodata!(
            :migration_table,
            "DuckDB does not support Ecto table engine options"
          )

        table.options ->
          unsupported_iodata!(:migration_table, "DuckDB does not support raw Ecto table :options")

        true ->
          :ok
      end
    end

    defp assert_constraint_options!(%Constraint{} = constraint) do
      cond do
        constraint.exclude ->
          unsupported_iodata!(
            :migration_constraint,
            "DuckDB does not support exclude constraints"
          )

        constraint.comment ->
          unsupported_iodata!(
            :migration_constraint,
            "DuckDB does not support constraint comments"
          )

        constraint.validate == false ->
          unsupported_iodata!(
            :migration_constraint,
            "DuckDB does not support NOT VALID constraints"
          )

        true ->
          :ok
      end
    end

    defp assert_index_options!(%Index{} = index) do
      cond do
        index.concurrently ->
          unsupported_iodata!(
            :migration_index,
            "DuckDB does not support concurrent index creation"
          )

        index.using ->
          unsupported_iodata!(
            :migration_index,
            "DuckDB does not support Ecto index :using options"
          )

        index.include != [] ->
          unsupported_iodata!(
            :migration_index,
            "DuckDB does not support covering index :include columns"
          )

        not is_nil(index.nulls_distinct) ->
          unsupported_iodata!(
            :migration_index,
            "DuckDB does not support Ecto index :nulls_distinct options"
          )

        index.comment ->
          unsupported_iodata!(:migration_index, "DuckDB does not support index comments")

        index.options ->
          unsupported_iodata!(:migration_index, "DuckDB does not support raw Ecto index :options")

        true ->
          :ok
      end
    end

    defp assert_index_drop_options!(%Index{} = index) do
      if index.concurrently do
        unsupported_iodata!(:migration_index, "DuckDB does not support concurrent index drops")
      end
    end

    @impl true
    def ddl_logs(_result), do: []

    @impl true
    def table_exists_query(table) do
      {"SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?", [table]}
    end

    defp dump_params(params), do: Enum.map(params, &dump_param/1)

    defp dump_param({:binary_id, value}), do: {:uuid, Ecto.UUID.cast!(value)}
    defp dump_param({:binary, value}), do: {:blob, value}
    defp dump_param(value) when is_map(value) and not is_struct(value), do: {:json, value}
    defp dump_param(value), do: value

    defp ensure_list_params!(params) do
      unless is_list(params) do
        raise ArgumentError, "expected params to be a list, got: #{inspect(params)}"
      end
    end

    defp insert_columns([]), do: []

    defp insert_columns(header) do
      [" (", header |> Enum.map(&quote_name/1) |> Enum.intersperse(", "), ")"]
    end

    defp insert_rows(%Ecto.Query{} = query),
      do: ["(", Ecto.Adapters.QuackDB.Query.all(query), ")"]

    defp insert_rows(rows) when is_list(rows) do
      [
        "VALUES ",
        rows
        |> Enum.map(fn row ->
          ["(", row |> Enum.map(&insert_value/1) |> Enum.intersperse(", "), ")"]
        end)
        |> Enum.intersperse(", ")
      ]
    end

    defp explain_row([_key, value]) when is_binary(value), do: value
    defp explain_row(row), do: Enum.map_join(row, "\t", &to_string/1)

    defp filters(filters) do
      filters
      |> Enum.map(fn
        {field, nil} -> [quote_name(field), " IS NULL"]
        {field, _value} -> [quote_name(field), " = ?"]
      end)
      |> Enum.intersperse(" AND ")
    end

    defp insert_value(nil), do: "?"

    defp insert_value({%Ecto.Query{} = query, _params_counter}),
      do: ["(", Ecto.Adapters.QuackDB.Query.all(query), ")"]

    defp insert_value({:placeholder, _placeholder_index}), do: "?"
    defp insert_value(_value), do: "?"

    defp on_conflict({:raise, _params, []}), do: []
    defp on_conflict({:nothing, _params, []}), do: " ON CONFLICT DO NOTHING"

    defp on_conflict({:nothing, _params, targets}) do
      [" ON CONFLICT ", conflict_target(targets), "DO NOTHING"]
    end

    defp on_conflict({%Ecto.Query{updates: updates}, _params, targets}) do
      [" ON CONFLICT ", conflict_target(targets), "DO UPDATE SET ", upsert_updates(updates)]
    end

    defp on_conflict({fields, _params, targets}) when is_list(fields) do
      [" ON CONFLICT ", conflict_target(targets), "DO UPDATE SET ", upsert_fields(fields)]
    end

    defp conflict_target([]), do: []

    defp conflict_target(targets) when is_list(targets) do
      ["(", targets |> Enum.map(&quote_name/1) |> Enum.intersperse(", "), ") "]
    end

    defp conflict_target({:unsafe_fragment, fragment}), do: [fragment, " "]

    defp upsert_updates(updates) do
      updates
      |> Enum.flat_map(fn %Ecto.Query.QueryExpr{expr: expressions} ->
        Enum.flat_map(expressions, fn
          {:set, fields} ->
            Enum.map(fields, fn {field, _expression} -> [quote_name(field), " = ?"] end)

          {:inc, fields} ->
            Enum.map(fields, fn {field, _expression} ->
              quoted = quote_name(field)
              [quoted, " = ", quoted, " + ?"]
            end)
        end)
      end)
      |> Enum.intersperse(", ")
    end

    defp upsert_fields(fields) do
      fields
      |> Enum.map(fn
        field when is_atom(field) ->
          quoted = quote_name(field)
          [quoted, " = EXCLUDED.", quoted]

        {field, _value} ->
          quoted = quote_name(field)
          [quoted, " = ?"]
      end)
      |> Enum.intersperse(", ")
    end

    defp returning([], _placeholders), do: []

    defp returning(returning, []),
      do: [" RETURNING ", returning |> Enum.map(&quote_name/1) |> Enum.intersperse(", ")]

    defp returning(_returning, _placeholders) do
      unsupported_iodata!(:placeholders, ":placeholders with RETURNING are unsupported")
    end

    defp serial_sequence_ddl(command, table, columns) do
      columns
      |> Enum.filter(fn
        {:add, _name, type, _options} -> type in [:serial, :bigserial]
        _other -> false
      end)
      |> Enum.map(fn {:add, name, _type, _options} ->
        [
          "CREATE SEQUENCE ",
          if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
          quote_name(serial_sequence_name(table, name))
        ]
      end)
    end

    defp pk_definition(columns, prefix) do
      pks =
        for {:add, name, _type, options} <- columns,
            Keyword.get(options, :primary_key, false),
            do: name

      case pks do
        [] ->
          []

        _pks ->
          [
            prefix,
            "PRIMARY KEY (",
            pks |> Enum.map(&quote_name/1) |> Enum.intersperse(", "),
            ")"
          ]
      end
    end

    defp column_definitions(table, columns) do
      Enum.map_intersperse(columns, ", ", &column_definition(table, &1))
    end

    defp column_definition(_table, {:add, name, %Reference{} = reference, options}) do
      [
        quote_name(name),
        " ",
        column_type(reference.type),
        column_options(options),
        reference_expr(reference)
      ]
    end

    defp column_definition(table, {:add, name, type, options})
         when type in [:serial, :bigserial] do
      [
        quote_name(name),
        " ",
        column_type(type),
        " DEFAULT nextval('",
        serial_sequence_name(table, name),
        "')",
        column_options(options)
      ]
    end

    defp column_definition(_table, {:add, name, type, options}) do
      [quote_name(name), " ", column_type(type), column_options(options)]
    end

    defp column_change({:add, name, %Reference{} = reference, options}) do
      [
        "ADD COLUMN ",
        quote_name(name),
        " ",
        column_type(reference.type),
        column_options(options),
        reference_expr(reference)
      ]
    end

    defp column_change({:add, name, type, options}) do
      ["ADD COLUMN ", quote_name(name), " ", column_type(type), column_options(options)]
    end

    defp column_change({:modify, name, type, options}) do
      [
        "ALTER COLUMN ",
        quote_name(name),
        " TYPE ",
        column_type(type),
        column_options(options)
      ]
    end

    defp column_change({:remove, name}), do: ["DROP COLUMN ", quote_name(name)]
    defp column_change({:remove, name, _type, _options}), do: column_change({:remove, name})

    defp column_options(options) do
      [
        null_option(Keyword.get(options, :null)),
        default_option(Keyword.fetch(options, :default))
      ]
    end

    defp null_option(false), do: " NOT NULL"
    defp null_option(true), do: " NULL"
    defp null_option(_other), do: []

    defp default_option(:error), do: []
    defp default_option({:ok, nil}), do: " DEFAULT NULL"
    defp default_option({:ok, {:fragment, expression}}), do: [" DEFAULT ", expression]

    defp default_option({:ok, value}) when is_binary(value),
      do: [" DEFAULT '", String.replace(value, "'", "''"), "'"]

    defp default_option({:ok, value}) when is_list(value) do
      [" DEFAULT ", QuackDB.SQL.literal!(value)]
    end

    defp default_option({:ok, %Decimal{} = value}),
      do: [" DEFAULT ", Decimal.to_string(value, :normal)]

    defp default_option({:ok, %Date{} = value}),
      do: [" DEFAULT DATE '", Date.to_iso8601(value), "'"]

    defp default_option({:ok, %Time{} = value}),
      do: [" DEFAULT TIME '", Time.to_iso8601(value), "'"]

    defp default_option({:ok, %NaiveDateTime{} = value}),
      do: [
        " DEFAULT TIMESTAMP '",
        value |> NaiveDateTime.to_iso8601() |> String.replace("T", " "),
        "'"
      ]

    defp default_option({:ok, %DateTime{} = value}),
      do: [" DEFAULT TIMESTAMPTZ '", DateTime.to_iso8601(value), "'"]

    defp default_option({:ok, value}) when is_number(value) or is_boolean(value),
      do: [" DEFAULT ", to_string(value)]

    defp default_option({:ok, value}) when is_map(value) and not is_struct(value) do
      [" DEFAULT ", QuackDB.SQL.literal!({:json, value})]
    end

    defp default_option({:ok, value}) do
      unsupported_iodata!(
        :migration_default,
        "unsupported migration default value: #{inspect(value)}"
      )
    end

    defp serial_sequence_name(%Table{} = table, column) do
      [table.prefix, table.name, column, "seq"]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("_", &to_string/1)
    end

    defp reference_expr(%Reference{} = reference) do
      [
        " REFERENCES ",
        quote_name(reference.prefix, reference.table),
        "(",
        quote_name(reference.column),
        ")",
        reference_action(:delete, reference.on_delete),
        reference_action(:update, reference.on_update)
      ]
    end

    defp reference_action(_kind, :nothing), do: []
    defp reference_action(:delete, action) when action in [:delete_all, :nilify_all], do: []
    defp reference_action(:delete, :restrict), do: " ON DELETE RESTRICT"
    defp reference_action(:update, action) when action in [:update_all, :nilify_all], do: []
    defp reference_action(:update, :restrict), do: " ON UPDATE RESTRICT"
    defp reference_action(_kind, _action), do: []

    defp column_type(type) do
      type
      |> QuackDB.Ecto.Type.column_type!(:migration)
      |> QuackDB.Type.to_sql()
    end

    defp table_options(nil), do: []

    defp index_expr(expression) when is_binary(expression), do: expression
    defp index_expr(expression), do: quote_name(expression)

    defp if_do(condition, value), do: if(condition, do: value, else: [])

    defp quote_name(name), do: QuackDB.Ecto.Quote.name(name)
    defp quote_name(prefix, name), do: QuackDB.Ecto.Quote.name(prefix, name)

    defp normalize_result(%QuackDB.Result{} = result) do
      %{
        command: result.command,
        columns: result.columns,
        rows: result.rows,
        num_rows: result.num_rows,
        connection_id: result.connection_id,
        messages: result.messages,
        metadata: result.metadata
      }
    end

    defp unsupported_iodata!(feature, message) do
      if Application.get_env(:quackdb, :allow_unsupported_ecto_sql_generation, false) do
        "-- unsupported QuackDB Ecto feature: #{feature}"
      else
        unsupported!(feature, message)
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

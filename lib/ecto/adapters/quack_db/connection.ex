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

    alias Ecto.Migration.{Index, Reference, Table}

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
      prepare_execute(connection, "", statement, params, options)
    end

    @impl true
    def query(connection, statement, params, options) do
      ensure_list_params!(params)

      case prepare_execute(connection, "", statement, params, options) do
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

    @impl true
    def insert(prefix, table, header, rows, on_conflict, returning, placeholders) do
      [
        "INSERT INTO ",
        quote_table(prefix, table),
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
        quote_table(prefix, table),
        " SET ",
        fields
        |> Enum.map(fn
          {field, _value} -> [quote_identifier(field), " = ?"]
          field -> [quote_identifier(field), " = ?"]
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
        quote_table(prefix, table),
        " WHERE ",
        filters(filters),
        returning(returning, [])
      ]
    end

    @impl true
    def explain_query(connection, query, params, options) do
      query(connection, ["EXPLAIN ", query], params, options)
    end

    @impl true
    def execute_ddl({command, %Table{} = table, columns})
        when command in [:create, :create_if_not_exists] do
      [
        [
          "CREATE TABLE ",
          if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
          quote_table(table.prefix, table.name),
          " (",
          column_definitions(table, columns),
          ")",
          table_options(table.options)
        ]
      ]
    end

    def execute_ddl({command, %Table{} = table, _mode})
        when command in [:drop, :drop_if_exists] do
      [
        [
          "DROP TABLE ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_table(table.prefix, table.name)
        ]
      ]
    end

    def execute_ddl({:alter, %Table{} = table, changes}) do
      Enum.map(changes, fn change ->
        ["ALTER TABLE ", quote_table(table.prefix, table.name), " ", column_change(change)]
      end)
    end

    def execute_ddl({command, %Index{} = index})
        when command in [:create, :create_if_not_exists] do
      [
        [
          "CREATE ",
          if_do(index.unique, "UNIQUE "),
          "INDEX ",
          if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
          quote_identifier(index.name),
          " ON ",
          quote_table(index.prefix, index.table),
          " (",
          index.columns |> Enum.map(&index_expr/1) |> Enum.intersperse(", "),
          ")",
          if_do(index.where, [" WHERE ", to_string(index.where)])
        ]
      ]
    end

    def execute_ddl({command, %Index{} = index}) when command in [:drop, :drop_if_exists] do
      [
        [
          "DROP INDEX ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_identifier(index.name)
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
          quote_table(table.prefix, table.name),
          " RENAME TO ",
          quote_identifier(new_table.name)
        ]
      ]
    end

    def execute_ddl({:rename, %Table{} = table, old_column, new_column}) do
      [
        [
          "ALTER TABLE ",
          quote_table(table.prefix, table.name),
          " RENAME COLUMN ",
          quote_identifier(old_column),
          " TO ",
          quote_identifier(new_column)
        ]
      ]
    end

    def execute_ddl(statement) when is_binary(statement), do: [statement]

    @impl true
    def ddl_logs(_result), do: []

    @impl true
    def table_exists_query(table) do
      {"SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?", [table]}
    end

    defp ensure_list_params!(params) do
      unless is_list(params) do
        raise ArgumentError, "expected params to be a list, got: #{inspect(params)}"
      end
    end

    defp insert_columns([]), do: []

    defp insert_columns(header) do
      [" (", header |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", "), ")"]
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

    defp filters(filters) do
      filters
      |> Enum.map(fn
        {field, nil} -> [quote_identifier(field), " IS NULL"]
        {field, _value} -> [quote_identifier(field), " = ?"]
      end)
      |> Enum.intersperse(" AND ")
    end

    defp insert_value(nil), do: "DEFAULT"

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
      ["(", targets |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", "), ") "]
    end

    defp conflict_target({:unsafe_fragment, fragment}), do: [fragment, " "]

    defp upsert_updates(updates) do
      updates
      |> Enum.flat_map(fn %Ecto.Query.QueryExpr{expr: expressions} ->
        Enum.flat_map(expressions, fn
          {:set, fields} ->
            Enum.map(fields, fn {field, _expression} -> [quote_identifier(field), " = ?"] end)

          {:inc, fields} ->
            Enum.map(fields, fn {field, _expression} ->
              quoted = quote_identifier(field)
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
          quoted = quote_identifier(field)
          [quoted, " = EXCLUDED.", quoted]

        {field, _value} ->
          quoted = quote_identifier(field)
          [quoted, " = ?"]
      end)
      |> Enum.intersperse(", ")
    end

    defp returning([], _placeholders), do: []

    defp returning(returning, []),
      do: [" RETURNING ", returning |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", ")]

    defp returning(_returning, _placeholders) do
      unsupported_iodata!(:placeholders, ":placeholders with RETURNING are unsupported")
    end

    defp column_definitions(table, columns) do
      definitions = Enum.map(columns, &column_definition(&1, table))
      pks = columns |> Enum.filter(&composite_pk?/1) |> Enum.map(&elem(&1, 1))

      case {table.primary_key, pks} do
        {:composite, [_ | _]} ->
          pk = [
            "PRIMARY KEY (",
            pks |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", "),
            ")"
          ]

          [pk | Enum.reverse(definitions)] |> Enum.reverse() |> Enum.intersperse(", ")

        _ ->
          Enum.intersperse(definitions, ", ")
      end
    end

    defp composite_pk?({:add, _name, _type, options}),
      do: Keyword.get(options, :primary_key, false)

    defp column_definition({:add, name, %Reference{} = reference, options}, table) do
      [
        quote_identifier(name),
        " ",
        column_type(reference.type),
        column_options(options, table),
        reference_expr(reference)
      ]
    end

    defp column_definition({:add, name, type, options}, table) do
      [quote_identifier(name), " ", column_type(type), column_options(options, table)]
    end

    defp column_change({:add, name, %Reference{} = reference, options}) do
      [
        "ADD COLUMN ",
        quote_identifier(name),
        " ",
        column_type(reference.type),
        column_options(options),
        reference_expr(reference)
      ]
    end

    defp column_change({:add, name, type, options}) do
      ["ADD COLUMN ", quote_identifier(name), " ", column_type(type), column_options(options)]
    end

    defp column_change({:modify, name, type, options}) do
      [
        "ALTER COLUMN ",
        quote_identifier(name),
        " TYPE ",
        column_type(type),
        column_options(options)
      ]
    end

    defp column_change({:remove, name}), do: ["DROP COLUMN ", quote_identifier(name)]
    defp column_change({:remove, name, _type, _options}), do: column_change({:remove, name})

    defp column_options(options, table \\ %Table{}) do
      [
        null_option(Keyword.get(options, :null)),
        default_option(Keyword.fetch(options, :default)),
        primary_key_option(
          table.primary_key != :composite and Keyword.get(options, :primary_key, false)
        )
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

    defp default_option({:ok, value}) when is_number(value) or is_boolean(value),
      do: [" DEFAULT ", to_string(value)]

    defp primary_key_option(true), do: " PRIMARY KEY"
    defp primary_key_option(false), do: []

    defp reference_expr(%Reference{} = reference) do
      [
        " REFERENCES ",
        quote_table(reference.prefix, reference.table),
        "(",
        quote_identifier(reference.column),
        ")",
        reference_action(:delete, reference.on_delete),
        reference_action(:update, reference.on_update)
      ]
    end

    defp reference_action(_kind, :nothing), do: []
    defp reference_action(:delete, :delete_all), do: " ON DELETE CASCADE"
    defp reference_action(:delete, :nilify_all), do: " ON DELETE SET NULL"
    defp reference_action(:delete, :restrict), do: " ON DELETE RESTRICT"
    defp reference_action(:update, :update_all), do: " ON UPDATE CASCADE"
    defp reference_action(:update, :nilify_all), do: " ON UPDATE SET NULL"
    defp reference_action(:update, :restrict), do: " ON UPDATE RESTRICT"
    defp reference_action(_kind, _action), do: []

    defp column_type(type) do
      type
      |> ecto_type_to_duckdb()
      |> QuackDB.Type.to_sql()
    end

    defp ecto_type_to_duckdb(:id), do: :bigint
    defp ecto_type_to_duckdb(:bigserial), do: :bigint
    defp ecto_type_to_duckdb(:serial), do: :integer
    defp ecto_type_to_duckdb(:binary_id), do: :uuid
    defp ecto_type_to_duckdb(:integer), do: :integer
    defp ecto_type_to_duckdb(:bigint), do: :bigint
    defp ecto_type_to_duckdb(:float), do: :double
    defp ecto_type_to_duckdb(:boolean), do: :boolean
    defp ecto_type_to_duckdb(:string), do: :varchar
    defp ecto_type_to_duckdb(:text), do: :varchar
    defp ecto_type_to_duckdb(:binary), do: :blob
    defp ecto_type_to_duckdb(:decimal), do: :decimal
    defp ecto_type_to_duckdb(:date), do: :date
    defp ecto_type_to_duckdb(type) when type in [:time, :time_usec], do: :time

    defp ecto_type_to_duckdb(type) when type in [:naive_datetime, :naive_datetime_usec],
      do: :timestamp

    defp ecto_type_to_duckdb(type) when type in [:utc_datetime, :utc_datetime_usec],
      do: :timestamptz

    defp ecto_type_to_duckdb({:array, type}), do: {:list, ecto_type_to_duckdb(type)}
    defp ecto_type_to_duckdb(type), do: type

    defp table_options(nil), do: []
    defp table_options(options), do: [" ", to_string(options)]

    defp index_expr(expression) when is_binary(expression), do: expression
    defp index_expr(expression), do: quote_identifier(expression)

    defp if_do(condition, value), do: if(condition, do: value, else: [])

    defp quote_table(nil, table), do: quote_identifier(table)
    defp quote_table(prefix, table), do: [quote_identifier(prefix), ".", quote_identifier(table)]

    defp quote_identifier(value) do
      value = value |> to_string() |> String.replace("\"", "\"\"")
      ["\"", value, "\""]
    end

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

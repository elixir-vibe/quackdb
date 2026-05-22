if Code.ensure_loaded?(Ecto.Adapters.SQL.Connection) do
  defmodule Ecto.Adapters.QuackDB.Connection do
    @moduledoc """
    Ecto SQL connection callbacks backed by `QuackDB.DBConnection`.

    This module currently implements the raw query path used by
    `Ecto.Adapters.SQL.query/4` and `Repo.query/3`. Higher-level Ecto query
    generation callbacks raise explicit unsupported-feature errors until the
    adapter grows beyond raw SQL execution.
    """

    @behaviour Ecto.Adapters.SQL.Connection

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
      unsupported!(:query_many, "multiple-result raw SQL is not supported yet")
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
    def all(%Ecto.Query{} = query) do
      assert_read_only_query!(query)

      [
        select(query.select),
        " FROM ",
        source(query.from),
        wheres(query.wheres),
        order_bys(query.order_bys),
        limit(query.limit),
        offset(query.offset)
      ]
    end

    @impl true
    def update_all(_query),
      do:
        unsupported_iodata!(
          :schema_updates,
          "Ecto update_all is not supported yet; use Repo.query/3"
        )

    @impl true
    def delete_all(_query),
      do:
        unsupported_iodata!(
          :schema_deletes,
          "Ecto delete_all is not supported yet; use Repo.query/3"
        )

    @impl true
    def insert(_prefix, _table, _header, _rows, _on_conflict, _returning, _placeholders) do
      unsupported_iodata!(:schema_inserts, "Ecto inserts are not supported yet; use Repo.query/3")
    end

    @impl true
    def update(_prefix, _table, _fields, _filters, _returning) do
      unsupported_iodata!(:schema_updates, "Ecto updates are not supported yet; use Repo.query/3")
    end

    @impl true
    def delete(_prefix, _table, _filters, _returning) do
      unsupported_iodata!(:schema_deletes, "Ecto deletes are not supported yet; use Repo.query/3")
    end

    @impl true
    def explain_query(_connection, _query, _params, _options) do
      unsupported!(:explain, "Ecto explain is not supported yet")
    end

    @impl true
    def execute_ddl(_command) do
      unsupported_iodata!(
        :migrations,
        "Ecto migrations are not supported yet; use Repo.query/3 for raw SQL"
      )
    end

    @impl true
    def ddl_logs(_result), do: []

    @impl true
    def table_exists_query(table) do
      {"SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?", [table]}
    end

    defp assert_read_only_query!(%Ecto.Query{} = query) do
      cond do
        query.joins != [] ->
          unsupported!(:joins, "Ecto joins are not supported yet; use Repo.query/3")

        query.group_bys != [] ->
          unsupported!(:group_by, "Ecto group_by is not supported yet; use Repo.query/3")

        query.havings != [] ->
          unsupported!(:having, "Ecto having is not supported yet; use Repo.query/3")

        query.distinct != nil ->
          unsupported!(:distinct, "Ecto distinct is not supported yet; use Repo.query/3")

        query.combinations != [] ->
          unsupported!(:combinations, "Ecto combinations are not supported yet; use Repo.query/3")

        query.with_ctes != nil ->
          unsupported!(:ctes, "Ecto CTEs are not supported yet; use Repo.query/3")

        query.lock != nil ->
          unsupported!(:locks, "Ecto locks are not supported yet; use Repo.query/3")

        true ->
          :ok
      end
    end

    defp select(nil), do: "SELECT *"

    defp select(%Ecto.Query.SelectExpr{expr: expr}) do
      ["SELECT ", select_expr(expr)]
    end

    defp select_expr({:%{}, _meta, fields}) do
      fields
      |> Enum.map(fn {alias_name, expr} -> [expr(expr), " AS ", quote_identifier(alias_name)] end)
      |> Enum.intersperse(", ")
    end

    defp select_expr({:{}, _meta, fields}) do
      fields |> Enum.map(&expr/1) |> Enum.intersperse(", ")
    end

    defp select_expr(fields) when is_list(fields) do
      fields |> Enum.map(&expr/1) |> Enum.intersperse(", ")
    end

    defp select_expr(expr), do: expr(expr)

    defp source(%Ecto.Query.FromExpr{source: {table, nil}}) when is_binary(table) do
      [quote_identifier(table), " AS q0"]
    end

    defp source(%Ecto.Query.FromExpr{source: {table, schema}})
         when is_binary(table) and is_atom(schema) do
      [quote_identifier(table), " AS q0"]
    end

    defp source(_from),
      do: unsupported!(:source, "only table sources are supported in Ecto queries")

    defp wheres([]), do: []

    defp wheres(wheres) do
      expressions = Enum.map(wheres, fn %{expr: expression} -> expr(expression) end)
      [" WHERE ", Enum.intersperse(expressions, " AND ")]
    end

    defp order_bys([]), do: []

    defp order_bys(order_bys) do
      expressions =
        order_bys
        |> Enum.flat_map(& &1.expr)
        |> Enum.map(fn {direction, expression} ->
          [expr(expression), " ", order_direction(direction)]
        end)

      [" ORDER BY ", Enum.intersperse(expressions, ", ")]
    end

    defp limit(nil), do: []
    defp limit(%{expr: expression}), do: [" LIMIT ", expr(expression)]

    defp offset(nil), do: []
    defp offset(%{expr: expression}), do: [" OFFSET ", expr(expression)]

    defp expr({{:., _meta, [{:&, _binding_meta, [0]}, field]}, _call_meta, []})
         when is_atom(field) do
      ["q0.", quote_identifier(field)]
    end

    defp expr({op, _meta, [left, right]}) when op in [:==, :!=, :>, :<, :>=, :<=] do
      ["(", expr(left), " ", operator(op), " ", expr(right), ")"]
    end

    defp expr({op, _meta, [left, right]}) when op in [:and, :or] do
      ["(", expr(left), " ", op |> Atom.to_string() |> String.upcase(), " ", expr(right), ")"]
    end

    defp expr({:^, _meta, [_index]}), do: "?"
    defp expr(%Ecto.Query.Tagged{value: value}), do: literal(value)
    defp expr(value) when is_binary(value), do: literal(value)
    defp expr(value) when is_integer(value) or is_float(value), do: to_string(value)
    defp expr(value) when is_boolean(value), do: if(value, do: "TRUE", else: "FALSE")
    defp expr(nil), do: "NULL"

    defp expr(other) do
      unsupported!(:expression, "unsupported Ecto query expression: #{inspect(other)}")
    end

    defp literal(value) when is_binary(value), do: ["'", String.replace(value, "'", "''"), "'"]
    defp literal(%Date{} = value), do: ["DATE '", Date.to_iso8601(value), "'"]

    defp literal(%NaiveDateTime{} = value),
      do: ["TIMESTAMP '", NaiveDateTime.to_iso8601(value), "'"]

    defp literal(%DateTime{} = value), do: ["TIMESTAMPTZ '", DateTime.to_iso8601(value), "'"]
    defp literal(%Decimal{} = value), do: Decimal.to_string(value)
    defp literal(value), do: expr(value)

    defp operator(:==), do: "="
    defp operator(:!=), do: "<>"
    defp operator(op), do: Atom.to_string(op)

    defp order_direction(:asc), do: "ASC"
    defp order_direction(:desc), do: "DESC"
    defp order_direction(:asc_nulls_last), do: "ASC NULLS LAST"
    defp order_direction(:asc_nulls_first), do: "ASC NULLS FIRST"
    defp order_direction(:desc_nulls_last), do: "DESC NULLS LAST"
    defp order_direction(:desc_nulls_first), do: "DESC NULLS FIRST"

    defp quote_identifier(value) do
      value = value |> to_string() |> String.replace("\"", "\"\"")
      ["\"", value, "\""]
    end

    defp ensure_list_params!(params) do
      unless is_list(params) do
        raise ArgumentError, "expected params to be a list, got: #{inspect(params)}"
      end
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

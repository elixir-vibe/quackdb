defmodule QuackDB.DML do
  import QuackDB.SQL.Fragment

  @moduledoc """
  Small DuckDB DML SQL builders.

  These helpers return SQL iodata for setup and example insert statements while
  still allowing DuckDB expressions where needed. For large batches, prefer
  `QuackDB.insert_rows/4`, `QuackDB.insert_columns/4`, or
  `QuackDB.Explorer.insert_dataframe/4`.
  """

  @type value :: QuackDB.SQL.parameter() | {:expr, iodata()}
  @type row :: keyword(value()) | %{(atom() | String.t()) => value()}
  @type table :: atom() | String.t() | {atom() | String.t() | nil, atom() | String.t()}
  @type where :: keyword(value())
  @type merge_insert :: {:insert, [atom() | String.t()]}

  @doc """
  Builds a parameterized `DELETE FROM ... WHERE ...` statement.

      {sql, params} =
        QuackDB.DML.delete_from(:events,
          where: [event_type: "session_entry", session_file: session_file]
        )

      QuackDB.query!(conn, sql, params)

  `nil` values generate `IS NULL` predicates. `{:expr, sql}` values are emitted
  directly for cases where a DuckDB expression is required.
  """
  @spec delete_from(table(), keyword()) :: {iodata(), [QuackDB.SQL.parameter()]}
  def delete_from(table, options) when is_list(options) do
    where = Keyword.get(options, :where, :missing)
    {predicates, params} = delete_predicates!(where)

    {
      [
        "DELETE FROM ",
        table(table),
        " WHERE ",
        Enum.intersperse(predicates, " AND ")
      ],
      params
    }
  end

  @doc "Builds an `INSERT INTO ... VALUES ...` statement."
  @spec insert_into(String.t() | atom(), [row()] | row()) :: iodata()
  def insert_into(table, rows) when is_list(rows) do
    rows = normalize_rows(rows)
    columns = columns!(rows)

    [
      "INSERT INTO ",
      table(table),
      " (",
      column_list(columns),
      ") VALUES ",
      rows |> Enum.map(&row_values(&1, columns)) |> Enum.intersperse(", ")
    ]
  end

  def insert_into(table, row) when is_map(row), do: insert_into(table, [row])

  @doc "Builds an `INSERT INTO ... SELECT ... FROM ...` statement."
  @spec insert_into_select(
          table(),
          [atom() | String.t()],
          table(),
          [atom() | String.t()],
          keyword()
        ) ::
          iodata()
  def insert_into_select(table, columns, source, select_columns, options \\ [])
      when is_list(columns) and is_list(select_columns) and is_list(options) do
    [
      "INSERT INTO ",
      table(table),
      insert_columns(columns),
      " SELECT ",
      select_columns(select_columns),
      " FROM ",
      table(source),
      on_conflict(Keyword.get(options, :on_conflict, :raise)),
      returning(Keyword.get(options, :returning, []))
    ]
  end

  @doc "Builds a `MERGE INTO ... USING ...` statement."
  @spec merge_into(table(), keyword()) :: iodata()
  def merge_into(target, options) when is_list(options) do
    source = Keyword.fetch!(options, :using)
    target_alias = Keyword.get(options, :target_as, :target)
    source_alias = Keyword.get(options, :source_as, :source)
    on = Keyword.fetch!(options, :on)
    not_matched = Keyword.get(options, :when_not_matched, :nothing)

    [
      "MERGE INTO ",
      table(target),
      " AS ",
      alias_name(target_alias),
      " USING ",
      table(source),
      " AS ",
      alias_name(source_alias),
      " ON ",
      merge_on(on, target_alias, source_alias),
      merge_not_matched(not_matched, source_alias),
      returning(Keyword.get(options, :returning, []))
    ]
  end

  defp delete_predicates!(:missing) do
    raise ArgumentError, "expected delete where: to be a non-empty keyword list"
  end

  defp delete_predicates!([]) do
    raise ArgumentError, "expected delete where: to include at least one predicate"
  end

  defp delete_predicates!(where) when is_list(where) do
    unless Keyword.keyword?(where) do
      raise ArgumentError, "expected delete where: to be a keyword list, got: #{inspect(where)}"
    end

    where
    |> Enum.map(&delete_predicate/1)
    |> Enum.unzip()
    |> then(fn {predicates, params} -> {predicates, :lists.append(params)} end)
  end

  defp delete_predicates!(where) do
    raise ArgumentError, "expected delete where: to be a keyword list, got: #{inspect(where)}"
  end

  defp delete_predicate({column, nil}) do
    {[column(column), " IS NULL"], []}
  end

  defp delete_predicate({column, {:expr, expression}}) do
    {[column(column), " = ", expression], []}
  end

  defp delete_predicate({column, value}) do
    {[column(column), " = ?"], [value]}
  end

  defp normalize_rows([]), do: []

  defp normalize_rows([{key, _value} | _rest] = row) when is_atom(key) or is_binary(key),
    do: [row]

  defp normalize_rows(rows), do: rows

  defp columns!([]), do: raise(ArgumentError, "expected at least one insert row")

  defp columns!([row | rows]) when is_list(row) do
    columns = Keyword.keys(row)
    validate_columns!(columns, rows)
  end

  defp columns!([row | rows]) when is_map(row) do
    columns = Map.keys(row)
    validate_columns!(columns, rows)
  end

  defp validate_columns!([], _rows),
    do: raise(ArgumentError, "expected at least one insert column")

  defp validate_columns!(columns, rows) do
    Enum.each(rows, fn row ->
      row_columns = row_columns(row)

      if row_columns != columns do
        raise ArgumentError,
              "insert rows must have identical columns, expected #{inspect(columns)}, got #{inspect(row_columns)}"
      end
    end)

    columns
  end

  defp row_columns(row) when is_list(row), do: Keyword.keys(row)
  defp row_columns(row) when is_map(row), do: Map.keys(row)

  defp row_values(row, columns) do
    ["(", columns |> Enum.map(&value(row, &1)) |> Enum.intersperse(", "), ")"]
  end

  defp merge_on(on, target_alias, source_alias) when is_list(on) and on != [] do
    on
    |> Enum.map(fn
      {column, column} ->
        merge_equality(target_alias, column, source_alias, column)

      {target_column, source_column} ->
        merge_equality(target_alias, target_column, source_alias, source_column)

      column ->
        merge_equality(target_alias, column, source_alias, column)
    end)
    |> Enum.intersperse(" AND ")
  end

  defp merge_on(on, _target_alias, _source_alias) do
    raise ArgumentError, "expected MERGE :on to include at least one column, got: #{inspect(on)}"
  end

  defp merge_equality(target_alias, target_column, source_alias, source_column) do
    qualified_equality(target_alias, target_column, source_alias, source_column)
  end

  defp merge_not_matched(:nothing, _source_alias), do: []

  defp merge_not_matched({:insert, columns}, source_alias)
       when is_list(columns) and columns != [] do
    [
      " WHEN NOT MATCHED THEN INSERT",
      insert_columns(columns),
      " VALUES (",
      merge_insert_values(columns, source_alias),
      ")"
    ]
  end

  defp merge_not_matched(other, _source_alias) do
    raise ArgumentError, "unsupported MERGE when_not_matched option: #{inspect(other)}"
  end

  defp merge_insert_values(columns, source_alias) do
    qualified_column_list(columns, source_alias)
  end

  defp value(row, column) do
    row
    |> fetch_value!(column)
    |> sql_value()
  end

  defp fetch_value!(row, column) when is_list(row), do: Keyword.fetch!(row, column)

  defp fetch_value!(row, column) when is_map(row) do
    case Map.fetch(row, column) do
      {:ok, value} -> value
      :error -> Map.fetch!(row, to_string(column))
    end
  end

  defp sql_value({:expr, value}), do: value

  defp sql_value(value) do
    case QuackDB.SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, %QuackDB.Error{} = error} -> raise error
    end
  end
end

defmodule QuackDB.DML do
  @moduledoc """
  Small DuckDB DML SQL builders.

  These helpers return SQL iodata for setup and example insert statements while
  still allowing DuckDB expressions where needed. For large batches, prefer
  `QuackDB.insert_rows/4`, `QuackDB.insert_columns/4`, or
  `QuackDB.Explorer.insert_dataframe/4`.
  """

  @type value :: QuackDB.SQL.parameter() | {:expr, iodata()}
  @type row :: keyword(value()) | %{(atom() | String.t()) => value()}

  @doc "Builds an `INSERT INTO ... VALUES ...` statement."
  @spec insert_into(String.t() | atom(), [row()] | row()) :: iodata()
  def insert_into(table, rows) when is_list(rows) do
    rows = normalize_rows(rows)
    columns = columns!(rows)

    [
      "INSERT INTO ",
      QuackDB.Type.quote_identifier(table),
      " (",
      columns |> Enum.map(&QuackDB.Type.quote_identifier/1) |> Enum.intersperse(", "),
      ") VALUES ",
      rows |> Enum.map(&row_values(&1, columns)) |> Enum.intersperse(", ")
    ]
  end

  def insert_into(table, row) when is_map(row), do: insert_into(table, [row])

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

defmodule QuackDB.SQL.Fragment do
  @moduledoc """
  Reusable SQL fragments shared by QuackDB statement builders.

  This module intentionally builds small, composable iodata fragments rather than
  introducing another statement-level DSL. Public DML/DDL helpers can reuse these
  fragments while keeping the number of top-level insert/update APIs small.
  """

  @type table :: atom() | String.t() | {atom() | String.t() | nil, atom() | String.t()}
  @type column :: atom() | String.t()
  @type alias_name :: atom() | String.t()
  @type order_direction :: :asc | :desc
  @type nulls_order :: :first | :last
  @type order_expression ::
          column()
          | {column(), order_direction()}
          | {column(), order_direction(), keyword()}

  @doc "Quotes a table name, optionally with a schema/prefix tuple."
  @spec table(table()) :: iodata()
  def table({nil, name}), do: QuackDB.Type.quote_identifier(name)

  def table({prefix, name}) do
    [QuackDB.Type.quote_identifier(prefix), ?., QuackDB.Type.quote_identifier(name)]
  end

  def table(name), do: QuackDB.Type.quote_identifier(name)

  @doc "Quotes a table alias."
  @spec alias_name(alias_name()) :: iodata()
  def alias_name(name), do: QuackDB.Type.quote_identifier(name)

  @doc "Quotes a column identifier."
  @spec column(column()) :: iodata()
  def column(name), do: QuackDB.Type.quote_identifier(name)

  @doc "Quotes a qualified column reference such as `source.id`."
  @spec qualified_column(alias_name(), column()) :: iodata()
  def qualified_column(table_alias, column) do
    [alias_name(table_alias), ?., column(column)]
  end

  @doc "Renders a comma-separated column list."
  @spec column_list([column()]) :: iodata()
  def column_list(columns) when is_list(columns) do
    columns |> Enum.map(&column/1) |> Enum.intersperse(", ")
  end

  @doc "Renders a comma-separated qualified column list."
  @spec qualified_column_list([column()], alias_name()) :: iodata()
  def qualified_column_list(columns, table_alias) when is_list(columns) do
    columns |> Enum.map(&qualified_column(table_alias, &1)) |> Enum.intersperse(", ")
  end

  @doc "Renders an optional parenthesized insert column list."
  @spec insert_columns([column()]) :: iodata()
  def insert_columns([]), do: []
  def insert_columns(columns), do: [" (", column_list(columns), ")"]

  @doc "Renders `*` for an empty select list, otherwise a column list."
  @spec select_columns([column()]) :: iodata()
  def select_columns([]), do: "*"
  def select_columns(columns), do: column_list(columns)

  @doc "Renders `RETURNING ...` for a non-empty column list."
  @spec returning([column()]) :: iodata()
  def returning([]), do: []
  def returning(columns), do: [" RETURNING ", column_list(columns)]

  @doc "Renders supported `ON CONFLICT` clauses."
  @spec on_conflict(:raise | :nothing | {:nothing, [column()]}) :: iodata()
  def on_conflict(:raise), do: []
  def on_conflict(:nothing), do: " ON CONFLICT DO NOTHING"

  def on_conflict({:nothing, targets}) when is_list(targets) do
    [" ON CONFLICT ", conflict_target(targets), "DO NOTHING"]
  end

  @doc "Renders a conflict target such as `(id, name)`, including trailing space."
  @spec conflict_target([column()]) :: iodata()
  def conflict_target([]), do: []
  def conflict_target(targets), do: ["(", column_list(targets), ") "]

  @doc "Renders equality between two qualified columns."
  @spec qualified_equality(alias_name(), column(), alias_name(), column()) :: iodata()
  def qualified_equality(left_alias, left_column, right_alias, right_column) do
    [
      qualified_column(left_alias, left_column),
      " = ",
      qualified_column(right_alias, right_column)
    ]
  end

  @doc "Renders `IS NOT DISTINCT FROM` between two qualified columns."
  @spec qualified_not_distinct(alias_name(), column(), alias_name(), column()) :: iodata()
  def qualified_not_distinct(left_alias, left_column, right_alias, right_column) do
    [
      qualified_column(left_alias, left_column),
      " IS NOT DISTINCT FROM ",
      qualified_column(right_alias, right_column)
    ]
  end

  @doc "Renders a parenthesized window partition column list."
  @spec partition_by([column()]) :: iodata()
  def partition_by(columns) when is_list(columns) and columns != [] do
    ["PARTITION BY ", column_list(columns)]
  end

  def partition_by(other) do
    raise ArgumentError, "expected at least one partition column, got: #{inspect(other)}"
  end

  @doc "Renders an optional `ORDER BY` clause for window expressions."
  @spec order_by([order_expression()]) :: iodata()
  def order_by([]), do: []

  def order_by(expressions) when is_list(expressions) do
    [" ORDER BY ", expressions |> Enum.map(&order_expression/1) |> Enum.intersperse(", ")]
  end

  @doc "Renders a `row_number() OVER (...) AS alias` expression."
  @spec row_number_over(keyword()) :: iodata()
  def row_number_over(options) when is_list(options) do
    partition_by = Keyword.fetch!(options, :partition_by)
    order_by = Keyword.get(options, :order_by, [])
    as = Keyword.get(options, :as, :row_number)

    [
      "row_number() OVER (",
      partition_by(partition_by),
      order_by(order_by),
      ") AS ",
      column(as)
    ]
  end

  @doc "Renders an optional `WHERE` clause from raw predicate iodata."
  @spec where(nil | iodata()) :: iodata()
  def where(nil), do: []
  def where(predicate), do: [" WHERE ", predicate]

  @doc "Renders a simple joined table clause."
  @spec join(:inner | :left, table(), keyword()) :: iodata()
  def join(kind, joined_table, options) when kind in [:inner, :left] and is_list(options) do
    [
      join_kind(kind),
      " JOIN ",
      table(joined_table),
      join_alias(Keyword.get(options, :as)),
      " ON ",
      Keyword.fetch!(options, :on)
    ]
  end

  defp order_expression({column, direction}) when direction in [:asc, :desc] do
    [column(column), " ", direction |> Atom.to_string() |> String.upcase()]
  end

  defp order_expression({column, direction, options})
       when direction in [:asc, :desc] and is_list(options) do
    [order_expression({column, direction}), nulls_order(Keyword.get(options, :nulls))]
  end

  defp order_expression(column), do: column(column)

  defp nulls_order(nil), do: []
  defp nulls_order(:first), do: " NULLS FIRST"
  defp nulls_order(:last), do: " NULLS LAST"

  defp nulls_order(other) do
    raise ArgumentError, "expected :nulls to be :first or :last, got: #{inspect(other)}"
  end

  defp join_kind(:inner), do: " INNER"
  defp join_kind(:left), do: " LEFT"

  defp join_alias(nil), do: []
  defp join_alias(as), do: [" AS ", alias_name(as)]
end

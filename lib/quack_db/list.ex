defmodule QuackDB.List do
  @moduledoc """
  SQL expression helpers for DuckDB LIST/ARRAY values.

  These helpers return iodata and map directly to DuckDB list functions. They are
  intentionally small building blocks for larger query modules.
  """

  @doc "Builds `len(list)`."
  @spec length(iodata()) :: iodata()
  def length(list_expression), do: call("len", [list_expression])

  @doc "Builds `list_extract(list, index)`. DuckDB list indexes are 1-based."
  @spec extract(iodata(), iodata()) :: iodata()
  def extract(list_expression, index_expression) do
    call("list_extract", [list_expression, index_expression])
  end

  @doc "Builds `list_slice(list, begin, end)`."
  @spec slice(iodata(), iodata(), iodata()) :: iodata()
  def slice(list_expression, begin_expression, end_expression) do
    call("list_slice", [list_expression, begin_expression, end_expression])
  end

  @doc "Builds `list_slice(list, begin, end, step)`."
  @spec slice(iodata(), iodata(), iodata(), iodata()) :: iodata()
  def slice(list_expression, begin_expression, end_expression, step_expression) do
    call("list_slice", [list_expression, begin_expression, end_expression, step_expression])
  end

  @doc "Builds `list_sort(list)`."
  @spec sort(iodata()) :: iodata()
  def sort(list_expression), do: call("list_sort", [list_expression])

  @doc "Builds `list_reverse_sort(list)`."
  @spec reverse_sort(iodata()) :: iodata()
  def reverse_sort(list_expression), do: call("list_reverse_sort", [list_expression])

  @doc "Builds `list_distinct(list)`."
  @spec distinct(iodata()) :: iodata()
  def distinct(list_expression), do: call("list_distinct", [list_expression])

  @doc "Builds `list_unique(list)`."
  @spec unique(iodata()) :: iodata()
  def unique(list_expression), do: call("list_unique", [list_expression])

  @doc "Builds `list_position(list, value)`."
  @spec position(iodata(), iodata()) :: iodata()
  def position(list_expression, value_expression) do
    call("list_position", [list_expression, value_expression])
  end

  @doc "Builds `list_contains(list, value)`."
  @spec contains(iodata(), iodata()) :: iodata()
  def contains(list_expression, value_expression) do
    call("list_contains", [list_expression, value_expression])
  end

  @doc "Builds `list_has_any(left, right)`."
  @spec has_any(iodata(), iodata()) :: iodata()
  def has_any(left_expression, right_expression) do
    call("list_has_any", [left_expression, right_expression])
  end

  @doc "Builds `list_has_all(left, right)`."
  @spec has_all(iodata(), iodata()) :: iodata()
  def has_all(left_expression, right_expression) do
    call("list_has_all", [left_expression, right_expression])
  end

  @doc "Builds `list_intersect(left, right)`."
  @spec intersect(iodata(), iodata()) :: iodata()
  def intersect(left_expression, right_expression) do
    call("list_intersect", [left_expression, right_expression])
  end

  @doc "Builds `list_concat(left, right)`."
  @spec concat(iodata(), iodata()) :: iodata()
  def concat(left_expression, right_expression) do
    call("list_concat", [left_expression, right_expression])
  end

  @doc "Builds `unnest(list)`."
  @spec unnest(iodata()) :: iodata()
  def unnest(list_expression), do: call("unnest", [list_expression])

  defp call(function, args) do
    [function, "(", Enum.intersperse(args, ", "), ")"]
  end
end

defmodule QuackDB.List do
  @moduledoc """
  SQL expression helpers for DuckDB LIST/ARRAY values.

  These helpers return iodata and map directly to DuckDB list functions. They are
  intentionally small building blocks for larger query modules.
  """

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

  @doc "Builds `unnest(list)`."
  @spec unnest(iodata()) :: iodata()
  def unnest(list_expression), do: call("unnest", [list_expression])

  defp call(function, args) do
    [function, "(", Enum.intersperse(args, ", "), ")"]
  end
end

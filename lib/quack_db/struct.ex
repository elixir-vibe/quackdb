defmodule QuackDB.Struct do
  @moduledoc """
  SQL expression helpers for DuckDB STRUCT values.

  These helpers return iodata and map directly to DuckDB struct functions.
  """

  @doc "Builds `struct_extract(struct, field_or_index)`."
  @spec extract(iodata(), iodata()) :: iodata()
  def extract(struct_expression, field_or_index_expression) do
    call("struct_extract", [struct_expression, field_or_index_expression])
  end

  @doc "Builds `struct_extract_at(struct, index)`."
  @spec extract_at(iodata(), iodata()) :: iodata()
  def extract_at(struct_expression, index_expression) do
    call("struct_extract_at", [struct_expression, index_expression])
  end

  @doc "Builds `struct_contains(struct, value)`."
  @spec contains(iodata(), iodata()) :: iodata()
  def contains(struct_expression, value_expression) do
    call("struct_contains", [struct_expression, value_expression])
  end

  @doc "Builds `struct_position(struct, value)`."
  @spec position(iodata(), iodata()) :: iodata()
  def position(struct_expression, value_expression) do
    call("struct_position", [struct_expression, value_expression])
  end

  @doc "Builds `struct_values(struct)`."
  @spec values(iodata()) :: iodata()
  def values(struct_expression), do: call("struct_values", [struct_expression])

  @doc "Builds `struct_concat(left, right)`."
  @spec concat(iodata(), iodata()) :: iodata()
  def concat(left_expression, right_expression) do
    call("struct_concat", [left_expression, right_expression])
  end

  defp call(function, args) do
    [function, "(", Enum.intersperse(args, ", "), ")"]
  end
end

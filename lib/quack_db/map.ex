defmodule QuackDB.Map do
  @moduledoc """
  SQL expression helpers for DuckDB MAP values.

  These helpers return iodata and map directly to DuckDB map functions.
  """

  @doc "Builds `cardinality(map)`."
  @spec cardinality(iodata()) :: iodata()
  def cardinality(map_expression), do: call("cardinality", [map_expression])

  @doc "Builds `map_keys(map)`."
  @spec keys(iodata()) :: iodata()
  def keys(map_expression), do: call("map_keys", [map_expression])

  @doc "Builds `map_values(map)`."
  @spec values(iodata()) :: iodata()
  def values(map_expression), do: call("map_values", [map_expression])

  @doc "Builds `map_entries(map)`."
  @spec entries(iodata()) :: iodata()
  def entries(map_expression), do: call("map_entries", [map_expression])

  @doc "Builds `map_contains(map, key)`."
  @spec contains(iodata(), iodata()) :: iodata()
  def contains(map_expression, key_expression) do
    call("map_contains", [map_expression, key_expression])
  end

  @doc "Builds `map_contains_entry(map, key, value)`."
  @spec contains_entry(iodata(), iodata(), iodata()) :: iodata()
  def contains_entry(map_expression, key_expression, value_expression) do
    call("map_contains_entry", [map_expression, key_expression, value_expression])
  end

  @doc "Builds `map_contains_value(map, value)`."
  @spec contains_value(iodata(), iodata()) :: iodata()
  def contains_value(map_expression, value_expression) do
    call("map_contains_value", [map_expression, value_expression])
  end

  @doc "Builds `map_extract(map, key)`."
  @spec extract(iodata(), iodata()) :: iodata()
  def extract(map_expression, key_expression) do
    call("map_extract", [map_expression, key_expression])
  end

  @doc "Builds `map_extract_value(map, key)`."
  @spec extract_value(iodata(), iodata()) :: iodata()
  def extract_value(map_expression, key_expression) do
    call("map_extract_value", [map_expression, key_expression])
  end

  @doc "Builds `map_concat(left, right)`."
  @spec concat(iodata(), iodata()) :: iodata()
  def concat(left_expression, right_expression) do
    call("map_concat", [left_expression, right_expression])
  end

  defp call(function, args) do
    [function, "(", Enum.intersperse(args, ", "), ")"]
  end
end

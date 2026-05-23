defmodule QuackDB.Source do
  @moduledoc """
  Safe SQL fragment builders for DuckDB table-producing data sources.

  DuckDB can query files, object stores, and lakehouse tables directly through
  table functions such as `read_parquet/2`, `read_csv/2`, `read_json/2`,
  `read_xlsx/2`, `delta_scan/2`, and `iceberg_scan/2`. This module builds those
  fragments with QuackDB's SQL literal formatting so callers do not need to
  manually interpolate paths or options.

  These helpers return SQL fragments, not executable queries. Use them in raw SQL
  that is sent to `QuackDB.query/4` or `Ecto.Adapters.SQL.query/4`:

      source = QuackDB.Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)
      QuackDB.query!(conn, ["SELECT count(*) FROM ", source])

  Options are emitted as DuckDB named parameters:

      QuackDB.Source.csv("events.csv", header: true, columns: %{id: "INTEGER", name: "VARCHAR"})

  Plain Elixir maps are formatted as DuckDB struct literals, which is the shape
  used by options such as `columns`. Use `{:map, map}` when a DuckDB `MAP {...}`
  literal is required.
  """

  alias QuackDB.Error
  alias QuackDB.SQL

  @type path_or_paths :: String.t() | [String.t()]
  @type option_value ::
          SQL.parameter()
          | atom()
          | %{optional(atom() | String.t() | integer()) => option_value()}
          | {:struct, keyword(option_value()) | map()}
          | {:map, map()}

  @doc "Builds a `read_parquet(...)` table function fragment."
  @spec parquet(path_or_paths(), keyword(option_value())) :: String.t()
  def parquet(path_or_paths, options \\ []),
    do: table_function("read_parquet", path_or_paths, options)

  @doc "Builds a `read_csv(...)` table function fragment."
  @spec csv(path_or_paths(), keyword(option_value())) :: String.t()
  def csv(path_or_paths, options \\ []), do: table_function("read_csv", path_or_paths, options)

  @doc "Builds a `read_json(...)` table function fragment."
  @spec json(path_or_paths(), keyword(option_value())) :: String.t()
  def json(path_or_paths, options \\ []), do: table_function("read_json", path_or_paths, options)

  @doc "Builds a `read_xlsx(...)` table function fragment."
  @spec xlsx(String.t(), keyword(option_value())) :: String.t()
  def xlsx(path, options \\ []) when is_binary(path),
    do: table_function("read_xlsx", path, options)

  @doc "Builds a `delta_scan(...)` table function fragment."
  @spec delta(path_or_paths(), keyword(option_value())) :: String.t()
  def delta(path_or_paths, options \\ []),
    do: table_function("delta_scan", path_or_paths, options)

  @doc "Builds an `iceberg_scan(...)` table function fragment."
  @spec iceberg(path_or_paths(), keyword(option_value())) :: String.t()
  def iceberg(path_or_paths, options \\ []),
    do: table_function("iceberg_scan", path_or_paths, options)

  @doc false
  @spec table_function(String.t(), path_or_paths(), keyword(option_value())) :: String.t()
  def table_function(function_name, path_or_paths, options \\ [])
      when is_binary(function_name) and is_list(options) do
    validate_identifier!(function_name, :function)

    [function_name, "(", literal!(path_or_paths), options(options), ")"]
    |> IO.iodata_to_binary()
  end

  @doc false
  @spec source?(term()) :: boolean()
  def source?(value) when is_binary(value) do
    Regex.match?(
      ~r/\A(?:read_parquet|read_csv|read_json|read_xlsx|delta_scan|iceberg_scan)\(/,
      value
    )
  end

  def source?(_value), do: false

  defp options([]), do: []

  defp options(options) do
    options =
      Enum.map(options, fn {name, value} ->
        [", ", option_name(name), " = ", literal!(value)]
      end)

    options
  end

  defp option_name(name) when is_atom(name), do: name |> Atom.to_string() |> option_name()

  defp option_name(name) when is_binary(name) do
    validate_identifier!(name, :option)
    name
  end

  defp option_name(name) do
    raise ArgumentError,
          "expected DuckDB option name to be an atom or string, got: #{inspect(name)}"
  end

  defp literal!({:struct, values}) when is_list(values) or is_map(values),
    do: struct_literal(values)

  defp literal!({:map, values}) when is_map(values), do: ["MAP ", map_entries(values)]
  defp literal!(values) when is_map(values), do: struct_literal(values)

  defp literal!(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: literal!(Atom.to_string(value))

  defp literal!(value) do
    case SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, %Error{} = error} -> raise error
    end
  end

  defp struct_literal(values), do: map_entries(values)

  defp map_entries(values) do
    entries =
      values
      |> Enum.map(fn {key, value} -> [literal_key(key), ": ", literal!(value)] end)
      |> Enum.intersperse(", ")

    ["{", entries, "}"]
  end

  defp literal_key(key) when is_atom(key), do: key |> Atom.to_string() |> literal_key()
  defp literal_key(key) when is_binary(key), do: ["'", String.replace(key, "'", "''"), "'"]
  defp literal_key(key) when is_integer(key), do: Integer.to_string(key)

  defp literal_key(key) do
    raise ArgumentError, "unsupported DuckDB literal key: #{inspect(key)}"
  end

  defp validate_identifier!(value, kind) do
    unless Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value) do
      raise ArgumentError, "invalid DuckDB #{kind} identifier: #{inspect(value)}"
    end
  end
end

defmodule QuackDB.Meta.Table do
  @moduledoc "A row from DuckDB's table listing pragmas."

  defstruct [:database, :schema, :name, :column_names, :column_types, :temporary]

  @type t :: %__MODULE__{
          database: String.t() | nil,
          schema: String.t() | nil,
          name: String.t() | nil,
          column_names: [String.t()] | nil,
          column_types: [String.t()] | nil,
          temporary: boolean() | nil
        }
end

defmodule QuackDB.Meta.Database do
  @moduledoc "A row from DuckDB's `PRAGMA database_list`."

  defstruct [:seq, :name, :file]

  @type t :: %__MODULE__{seq: integer() | nil, name: String.t() | nil, file: String.t() | nil}
end

defmodule QuackDB.Meta.Column do
  @moduledoc "A row from DuckDB's `pragma_table_info` table function."

  defstruct [:cid, :name, :type, :notnull, :dflt_value, :pk]

  @type t :: %__MODULE__{
          cid: integer() | nil,
          name: String.t() | nil,
          type: String.t() | nil,
          notnull: boolean() | nil,
          dflt_value: String.t() | nil,
          pk: boolean() | nil
        }
end

defmodule QuackDB.Meta do
  @moduledoc """
  DuckDB catalog and metadata helpers.

  These functions wrap DuckDB's logical metadata pragmas and table functions.
  They accept either a QuackDB connection or a QuackDB-backed Ecto repo. Table
  arguments may be schema modules, atoms, strings, or `{prefix, source}` tuples.
  """

  alias QuackDB.Meta.Column
  alias QuackDB.Meta.Database
  alias QuackDB.Meta.Table

  @type source :: module() | atom() | String.t() | {atom() | String.t(), atom() | String.t()}

  @doc "Lists tables visible to the current DuckDB connection."
  @spec tables(DBConnection.conn() | module(), keyword()) ::
          {:ok, [Table.t()]} | {:error, Exception.t()}
  def tables(connection, options \\ []) do
    expanded? = Keyword.get(options, :expanded, false)
    query_options = Keyword.delete(options, :expanded)
    statement = if expanded?, do: "PRAGMA show_tables_expanded", else: "PRAGMA show_tables"

    with {:ok, result} <- QuackDB.query(connection, statement, [], query_options) do
      {:ok, table_rows(result, expanded?)}
    end
  end

  @doc "Lists tables visible to the current DuckDB connection, raising on errors."
  @spec tables!(DBConnection.conn() | module(), keyword()) :: [Table.t()]
  def tables!(connection, options \\ []) do
    case tables(connection, options) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  @doc "Lists attached DuckDB databases."
  @spec databases(DBConnection.conn() | module(), keyword()) ::
          {:ok, [Database.t()]} | {:error, Exception.t()}
  def databases(connection, options \\ []) do
    with {:ok, result} <- QuackDB.query(connection, "PRAGMA database_list", [], options) do
      {:ok, rows_to_structs(result, Database)}
    end
  end

  @doc "Lists attached DuckDB databases, raising on errors."
  @spec databases!(DBConnection.conn() | module(), keyword()) :: [Database.t()]
  def databases!(connection, options \\ []) do
    case databases(connection, options) do
      {:ok, databases} -> databases
      {:error, error} -> raise error
    end
  end

  @doc "Returns logical column metadata for a table."
  @spec table_info(DBConnection.conn() | module(), source(), keyword()) ::
          {:ok, [Column.t()]} | {:error, Exception.t()}
  def table_info(connection, source, options \\ []) do
    statement = QuackDB.SQL.call(:pragma_table_info, [source_name(source)])

    with {:ok, result} <- QuackDB.query(connection, statement, [], options) do
      {:ok, rows_to_structs(result, Column)}
    end
  end

  @doc "Returns logical column metadata for a table, raising on errors."
  @spec table_info!(DBConnection.conn() | module(), source(), keyword()) :: [Column.t()]
  def table_info!(connection, source, options \\ []) do
    case table_info(connection, source, options) do
      {:ok, columns} -> columns
      {:error, error} -> raise error
    end
  end

  defp table_rows(result, true), do: rows_to_structs(result, Table)

  defp table_rows(%QuackDB.Result{columns: ["name"], rows: rows}, false) when is_list(rows) do
    Enum.map(rows, fn [name] -> %Table{name: name} end)
  end

  defp table_rows(result, false), do: rows_to_structs(result, Table)

  defp rows_to_structs(%QuackDB.Result{columns: columns, rows: rows}, module)
       when is_list(columns) and is_list(rows) do
    fields = Map.keys(struct!(module)) -- [:__struct__]

    Enum.map(rows, fn row ->
      data =
        columns
        |> Enum.map(&normalize_key/1)
        |> Enum.zip(row)
        |> Map.new()
        |> Map.take(fields)

      struct!(module, data)
    end)
  end

  defp rows_to_structs(%QuackDB.Result{}, _module), do: []

  defp normalize_key(key) when is_binary(key) do
    key
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end

  defp source_name({prefix, source}), do: Enum.map_join([prefix, source], ".", &source_part/1)

  defp source_name(source) when is_atom(source) do
    if Code.ensure_loaded?(source) and function_exported?(source, :__schema__, 1) do
      schema_source_name(source)
    else
      Atom.to_string(source)
    end
  end

  defp source_name(source) when is_binary(source), do: source

  defp schema_source_name(schema) do
    case apply(schema, :__schema__, [:prefix]) do
      nil -> apply(schema, :__schema__, [:source])
      prefix -> source_name({prefix, apply(schema, :__schema__, [:source])})
    end
  rescue
    FunctionClauseError -> apply(schema, :__schema__, [:source])
  end

  defp source_part(value) when is_atom(value), do: Atom.to_string(value)
  defp source_part(value) when is_binary(value), do: value
end

defmodule QuackDB.DDL do
  @moduledoc """
  Small DuckDB DDL SQL builders.

  These helpers return SQL iodata for common analytical setup tasks such as
  temporary tables in tests or notebooks. They are not an Ecto migration layer;
  execute the generated SQL with `QuackDB.query/4` or `Repo.query/3`.

      QuackDB.DDL.create_table("events",
        [
          id: :integer,
          name: :varchar,
          payload: :json,
          occurred_at: :timestamp
        ],
        temporary: true,
        if_not_exists: true
      )

  """

  @type column_type :: QuackDB.Type.spec()
  @type column ::
          {atom() | String.t(), column_type()} | {atom() | String.t(), column_type(), keyword()}

  @type create_table_option :: {:temporary, boolean()} | {:if_not_exists, boolean()}

  @doc "Builds a `CREATE TABLE` statement from an Ecto schema module."
  @spec create_table(module()) :: iodata()
  def create_table(schema) when is_atom(schema), do: create_table(schema, [])

  @spec create_table(module(), [create_table_option()]) :: iodata()
  def create_table(schema, options) when is_atom(schema) and is_list(options) do
    create_table(schema.__schema__(:source), schema_columns(schema), options)
  end

  @doc "Builds a `CREATE TABLE` statement."
  @spec create_table(String.t() | atom(), [column()], [create_table_option()]) :: iodata()
  def create_table(name, columns, options \\ []) when is_list(columns) and is_list(options) do
    [
      "CREATE ",
      temporary(options),
      "TABLE ",
      if_not_exists(options),
      QuackDB.Type.quote_identifier(name),
      " (",
      columns(columns),
      ")"
    ]
  end

  @doc "Builds a `DROP TABLE` statement."
  @spec drop_table(String.t() | atom(), keyword()) :: iodata()
  def drop_table(name, options \\ []) when is_list(options) do
    ["DROP TABLE ", if_exists(options), QuackDB.Type.quote_identifier(name)]
  end

  defp schema_columns(schema) do
    Enum.map(schema.__schema__(:fields), fn field ->
      {field, schema_field_type!(schema, field)}
    end)
  end

  defp schema_field_type!(schema, field) do
    schema.__schema__(:type, field)
    |> ecto_type_to_duckdb()
  rescue
    error in ArgumentError ->
      raise ArgumentError,
            "unsupported Ecto schema type for #{inspect(schema)}.#{field}: #{Exception.message(error)}"
  end

  defp ecto_type_to_duckdb(:id), do: :bigint
  defp ecto_type_to_duckdb(:binary_id), do: :uuid
  defp ecto_type_to_duckdb(:integer), do: :integer
  defp ecto_type_to_duckdb(:float), do: :double
  defp ecto_type_to_duckdb(:boolean), do: :boolean
  defp ecto_type_to_duckdb(:string), do: :varchar
  defp ecto_type_to_duckdb(:binary), do: :blob
  defp ecto_type_to_duckdb(:decimal), do: :decimal
  defp ecto_type_to_duckdb(:date), do: :date
  defp ecto_type_to_duckdb(:time), do: :time
  defp ecto_type_to_duckdb(:time_usec), do: :time
  defp ecto_type_to_duckdb(:naive_datetime), do: :timestamp
  defp ecto_type_to_duckdb(:naive_datetime_usec), do: :timestamp
  defp ecto_type_to_duckdb(:utc_datetime), do: :timestamptz
  defp ecto_type_to_duckdb(:utc_datetime_usec), do: :timestamptz
  defp ecto_type_to_duckdb({:array, type}), do: {:list, ecto_type_to_duckdb(type)}

  defp ecto_type_to_duckdb(type) do
    raise ArgumentError, inspect(type)
  end

  defp temporary(options) do
    if Keyword.get(options, :temporary, false), do: "TEMP ", else: []
  end

  defp if_not_exists(options) do
    if Keyword.get(options, :if_not_exists, false), do: "IF NOT EXISTS ", else: []
  end

  defp if_exists(options) do
    if Keyword.get(options, :if_exists, false), do: "IF EXISTS ", else: []
  end

  defp columns([]), do: raise(ArgumentError, "expected at least one column")

  defp columns(columns) do
    columns
    |> Enum.map(&column/1)
    |> Enum.intersperse(", ")
  end

  defp column({name, type}) do
    [QuackDB.Type.quote_identifier(name), " ", QuackDB.Type.to_sql(type)]
  end

  defp column({name, type, options}) when is_list(options) do
    [
      QuackDB.Type.quote_identifier(name),
      " ",
      QuackDB.Type.to_sql(type),
      column_options(options)
    ]
  end

  defp column(other) do
    raise ArgumentError, "expected column as {name, type}, got: #{inspect(other)}"
  end

  defp column_options(options) do
    [
      nullable(options),
      primary_key(options),
      default(options)
    ]
  end

  defp nullable(options) do
    if Keyword.get(options, :null, true), do: [], else: " NOT NULL"
  end

  defp primary_key(options) do
    if Keyword.get(options, :primary_key, false), do: " PRIMARY KEY", else: []
  end

  defp default(options) do
    case Keyword.fetch(options, :default) do
      {:ok, value} -> [" DEFAULT ", literal!(value)]
      :error -> []
    end
  end

  defp literal!(value) do
    case QuackDB.SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, %QuackDB.Error{} = error} -> raise error
    end
  end
end

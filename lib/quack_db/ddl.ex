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

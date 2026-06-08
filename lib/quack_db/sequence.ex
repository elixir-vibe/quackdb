defmodule QuackDB.Sequence do
  @moduledoc """
  Helpers for DuckDB sequences.

  Native append writes full column vectors and does not evaluate column defaults.
  Use `next_values/4` to allocate sequence-backed IDs before appending rows
  with explicit primary keys.
  """

  @doc """
  Returns the sequence backing a table column default.

  This inspects `pragma_table_info` and returns the sequence referenced by a
  `nextval('...')` default.
  """
  @spec for_column(
          DBConnection.conn() | module(),
          QuackDB.Meta.source(),
          atom() | String.t(),
          Keyword.t()
        ) ::
          {:ok, String.t()} | {:error, Exception.t()}
  def for_column(connection, source, column, options \\ []) do
    with {:ok, columns} <- QuackDB.Meta.table_info(connection, table_source(source), options) do
      column_name = column_source(source, column)

      columns
      |> Enum.find(&(&1.name == to_string(column_name)))
      |> sequence_from_column(source, column)
    end
  end

  @doc "Returns the sequence backing a table column default, raising on errors."
  @spec for_column!(
          DBConnection.conn() | module(),
          QuackDB.Meta.source(),
          atom() | String.t(),
          Keyword.t()
        ) ::
          String.t()
  def for_column!(connection, source, column, options \\ []) do
    case for_column(connection, source, column, options) do
      {:ok, sequence} -> sequence
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns `count` values from a DuckDB sequence.

      ids = QuackDB.Sequence.next_values(conn, "fragments_id_seq", 3)
      #=> [1, 2, 3]

  The sequence name is encoded as a SQL string literal for `nextval/1`; callers
  should pass the actual DuckDB sequence name, not raw SQL.
  """
  @spec next_values(DBConnection.conn(), atom() | String.t(), non_neg_integer(), Keyword.t()) :: [
          integer()
        ]
  def next_values(connection, sequence_name, count, options \\ [])

  def next_values(connection, sequence_name, count, options)
      when (is_atom(sequence_name) or is_binary(sequence_name)) and is_integer(count) and
             count >= 0 do
    statement = [
      "SELECT nextval(",
      QuackDB.SQL.literal!(to_string(sequence_name)),
      ") AS value FROM range(",
      Integer.to_string(count),
      ")"
    ]

    connection
    |> QuackDB.query!(statement, [], options)
    |> values_from_result()
  end

  def next_values(_connection, sequence_name, count, _options) do
    raise ArgumentError,
          "expected a sequence name atom/string and a non-negative count, got: #{inspect(sequence_name)}, #{inspect(count)}"
  end

  defp values_from_result(%QuackDB.Result{rows: rows}) when is_list(rows) do
    Enum.map(rows, fn [value] -> value end)
  end

  defp sequence_from_column(nil, source, column) do
    {:error,
     QuackDB.Error.new(
       :column_not_found,
       "could not find column #{inspect(column)} in #{inspect(source)}",
       source: :client
     )}
  end

  defp sequence_from_column(%QuackDB.Meta.Column{dflt_value: default}, source, column) do
    case parse_nextval_default(default) do
      {:ok, sequence} ->
        {:ok, sequence}

      :error ->
        {:error,
         QuackDB.Error.new(
           :sequence_not_found,
           "column #{inspect(column)} in #{inspect(source)} is not backed by a nextval default",
           source: :client,
           metadata: %{default: default}
         )}
    end
  end

  defp parse_nextval_default(default) when is_binary(default) do
    case Regex.run(~r/^nextval\('((?:''|[^'])+)'/, default) do
      [_match, sequence] -> {:ok, String.replace(sequence, "''", "'")}
      _other -> :error
    end
  end

  defp parse_nextval_default(_default), do: :error

  defp table_source({source, schema}) when is_atom(schema) do
    if ecto_schema?(schema) do
      case schema_prefix(schema) do
        nil -> source
        prefix -> {prefix, source}
      end
    else
      {source, schema}
    end
  end

  defp table_source(source), do: source

  defp column_source(source, column) when is_atom(column) do
    case schema_from_source(source) do
      nil -> column
      schema -> schema_field_source(schema, column)
    end
  end

  defp column_source(_source, column), do: column

  defp schema_from_source({_source, schema}) when is_atom(schema) do
    if ecto_schema?(schema), do: schema
  end

  defp schema_from_source(schema) when is_atom(schema) do
    if ecto_schema?(schema), do: schema
  end

  defp schema_from_source(_source), do: nil

  defp ecto_schema?(schema) do
    Code.ensure_loaded?(schema) and function_exported?(schema, :__schema__, 1)
  end

  defp schema_field_source(schema, field) do
    schema.__schema__(:field_source, field)
  rescue
    FunctionClauseError -> field
  end

  defp schema_prefix(schema) do
    schema.__schema__(:prefix)
  rescue
    FunctionClauseError -> nil
  end
end

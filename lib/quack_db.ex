defmodule QuackDB do
  @moduledoc """
  Remote DuckDB Quack protocol client.

  The public API is backed by `DBConnection` so it can grow into an Ecto adapter
  without changing the lower-level protocol codec.
  """

  alias QuackDB.Query
  alias QuackDB.Stream

  @type start_option :: {:uri, String.t()} | {:token, String.t()} | {:name, GenServer.name()}

  @spec start_link([start_option]) :: GenServer.on_start()
  def start_link(options) do
    QuackDB.DBConnection.start_link(options)
  end

  @spec child_spec([start_option]) :: Supervisor.child_spec()
  def child_spec(options) do
    QuackDB.DBConnection.child_spec(options)
  end

  @spec query(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def query(connection, statement, params \\ [], options \\ []) do
    query = %Query{statement: statement}

    case DBConnection.prepare_execute(connection, query, params, options) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _error} = error -> error
    end
  end

  @spec query!(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: QuackDB.Result.t()
  def query!(connection, statement, params \\ [], options \\ []) do
    case query(connection, statement, params, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @spec ping(DBConnection.conn(), Keyword.t()) :: :ok | {:error, Exception.t()}
  def ping(connection, options \\ []) do
    case query(connection, "SELECT 1", [], options) do
      {:ok, _result} -> :ok
      {:error, _error} = error -> error
    end
  end

  @spec prepare(DBConnection.conn(), iodata(), Keyword.t()) ::
          {:ok, Query.t()} | {:error, Exception.t()}
  def prepare(connection, statement, options \\ []) do
    DBConnection.prepare(connection, %Query{statement: statement}, options)
  end

  @spec prepare_execute(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, Query.t(), QuackDB.Result.t()} | {:error, Exception.t()}
  def prepare_execute(connection, statement, params \\ [], options \\ []) do
    DBConnection.prepare_execute(connection, %Query{statement: statement}, params, options)
  end

  @spec stream(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: Stream.t()
  def stream(connection, statement, params \\ [], options \\ []) do
    %Stream{
      conn: connection,
      query: %Query{statement: statement},
      params: params,
      options: options
    }
  end

  @spec rows(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: Enumerable.t()
  def rows(connection, statement, params \\ [], options \\ []) do
    connection
    |> stream(statement, params, options)
    |> Elixir.Stream.flat_map(&(&1.rows || []))
  end

  @spec maps(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: Enumerable.t()
  def maps(connection, statement, params \\ [], options \\ []) do
    connection
    |> stream(statement, params, options)
    |> Elixir.Stream.flat_map(&result_maps/1)
  end

  defp result_maps(%QuackDB.Result{columns: columns, rows: rows})
       when is_list(columns) and is_list(rows) do
    map_keys = disambiguate_columns(columns)
    Enum.map(rows, fn row -> map_keys |> Enum.zip(row) |> Map.new() end)
  end

  defp result_maps(_result), do: []

  defp disambiguate_columns(columns) do
    {columns, _counts} =
      Enum.map_reduce(columns, %{}, fn column, counts ->
        counts = Map.update(counts, column, 1, &(&1 + 1))

        case counts[column] do
          1 -> {column, counts}
          count -> {"#{column}_#{count}", counts}
        end
      end)

    columns
  end
end

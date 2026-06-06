defmodule QuackDB do
  @moduledoc """
  Remote DuckDB Quack protocol client.

  The public API is backed by `DBConnection` so it can grow into an Ecto adapter
  without changing the lower-level protocol codec.
  """

  alias QuackDB.Query
  alias QuackDB.Stream

  @type start_option ::
          {:uri, String.t()}
          | {:token, String.t()}
          | {:name, GenServer.name()}
          | {:connect_timeout, timeout()}
          | {:receive_timeout, timeout()}
          | {:shutdown_timeout, timeout()}
          | {:mint_options, keyword()}
  @type insert_row :: map() | Keyword.t()
  @type insert_column :: {atom() | String.t(), [term()]}

  @typedoc "Native append column type specs."
  @type append_type :: QuackDB.Type.spec()

  @spec start_link([start_option]) :: GenServer.on_start()
  def start_link(options) do
    QuackDB.DBConnection.start_link(options)
  end

  @spec child_spec([start_option]) :: Supervisor.child_spec()
  def child_spec(options) do
    QuackDB.DBConnection.child_spec(options)
  end

  @doc """
  Appends row-oriented values to a DuckDB table through Quack's native append protocol.

  Rows are maps or keywords. Pass `:columns` with type specs when values are empty,
  contain only nils, or need a specific nested DuckDB type.

  Plain Elixir maps infer as DuckDB `STRUCT` values. For explicit
  `{:map, key_type, value_type}` columns, ordinary Elixir maps are encoded as
  DuckDB `MAP` values:

      QuackDB.insert_rows!(conn, "events", [[labels: %{env: "prod"}]],
        columns: [labels: {:map, :varchar, :varchar}]
      )

  DuckDB-style key/value entries are also accepted for explicit MAP columns:

      QuackDB.insert_rows!(conn, "events", [[labels: [%{key: "env", value: "prod"}]]],
        columns: [labels: {:map, :varchar, :varchar}]
      )

  Duplicate MAP keys decode with the later entry winning, matching `Map.put/3`.
  Keys and values are encoded through the declared DuckDB key/value types; for
  example, atom keys in `{:map, :varchar, :varchar}` columns become strings.
  """
  @spec insert_rows(DBConnection.conn(), String.t() | atom(), [insert_row()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def insert_rows(connection, table, rows, options \\ []) when is_list(rows) do
    with_connection(connection, options, fn conn ->
      query = %Query{
        statement: "APPEND #{table}",
        operation: {:insert_rows, table, rows, options}
      }

      case DBConnection.prepare_execute(conn, query, [], options) do
        {:ok, _query, result} -> {:ok, result}
        {:error, _error} = error -> error
      end
    end)
  end

  @spec insert_rows!(DBConnection.conn(), String.t() | atom(), [insert_row()], Keyword.t()) ::
          QuackDB.Result.t()
  def insert_rows!(connection, table, rows, options \\ []) do
    case insert_rows(connection, table, rows, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Appends column-oriented values to a DuckDB table through Quack's native append protocol.

  Column values are provided as `{name, values}` pairs. All columns must have the
  same row count. Pass `:columns` with type specs when values are empty, contain
  only nils, or need a specific nested DuckDB type. Explicit MAP columns accept
  ordinary Elixir maps and DuckDB-style key/value entries.
  """
  @spec insert_columns(DBConnection.conn(), String.t() | atom(), [insert_column()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def insert_columns(connection, table, columns, options \\ []) when is_list(columns) do
    with_connection(connection, options, fn conn ->
      query = %Query{
        statement: "APPEND #{table}",
        operation: {:insert_columns, table, columns, options}
      }

      case DBConnection.prepare_execute(conn, query, [], options) do
        {:ok, _query, result} -> {:ok, result}
        {:error, _error} = error -> error
      end
    end)
  end

  @spec insert_columns!(DBConnection.conn(), String.t() | atom(), [insert_column()], Keyword.t()) ::
          QuackDB.Result.t()
  def insert_columns!(connection, table, columns, options \\ []) do
    case insert_columns(connection, table, columns, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Appends an enumerable of row maps/keywords in batches through native append."
  @spec insert_stream(DBConnection.conn(), String.t() | atom(), Enumerable.t(), Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def insert_stream(connection, table, rows, options \\ []) do
    chunk_every = Keyword.get(options, :chunk_every, Keyword.get(options, :batch_size, 1000))

    if not (is_integer(chunk_every) and chunk_every > 0) do
      raise ArgumentError,
            "expected :chunk_every to be a positive integer, got: #{inspect(chunk_every)}"
    end

    rows
    |> Elixir.Stream.chunk_every(chunk_every)
    |> Enum.reduce_while({:ok, nil, 0}, fn batch, {:ok, _result, total_rows} ->
      case insert_rows(connection, table, batch, options) do
        {:ok, result} -> {:cont, {:ok, result, total_rows + result.num_rows}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, nil, _total_rows} -> {:ok, nil}
      {:ok, result, total_rows} -> {:ok, %{result | num_rows: total_rows}}
      {:error, error} -> {:error, error}
    end
  end

  @spec insert_stream!(DBConnection.conn(), String.t() | atom(), Enumerable.t(), Keyword.t()) ::
          QuackDB.Result.t() | nil
  def insert_stream!(connection, table, rows, options \\ []) do
    case insert_stream(connection, table, rows, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  if Code.ensure_loaded?(Table.Reader) do
    @doc "Appends any `Table.Reader` compatible tabular data through native append."
    def insert_table(connection, table, tabular, options \\ []) do
      columns =
        Table.to_columns(tabular)
        |> Enum.map(fn {name, values} -> {name, Enum.to_list(values)} end)

      insert_columns(connection, table, columns, options)
    end

    def insert_table!(connection, table, tabular, options \\ []) do
      case insert_table(connection, table, tabular, options) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end
  end

  @spec query(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def query(connection, statement, params \\ [], options \\ []) do
    with_connection(connection, options, fn conn ->
      query = %Query{statement: statement}

      case DBConnection.prepare_execute(conn, query, params, options) do
        {:ok, _query, result} -> {:ok, result}
        {:error, _error} = error -> error
      end
    end)
  end

  @spec query!(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: QuackDB.Result.t()
  def query!(connection, statement, params \\ [], options \\ []) do
    case query(connection, statement, params, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Runs a query and returns its result as a column-oriented map.

  Duplicate column names are disambiguated with suffixes such as `_2` and `_3`.
  Prefer `columnar/4` when you also need column order and result metadata.
  """
  @spec columns(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, %{String.t() => [term()]}} | {:error, Exception.t()}
  def columns(connection, statement, params \\ [], options \\ []) do
    case query(connection, statement, params, options) do
      {:ok, result} -> {:ok, QuackDB.Result.to_columns(result)}
      {:error, _error} = error -> error
    end
  end

  @spec columns!(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: %{
          String.t() => [term()]
        }
  def columns!(connection, statement, params \\ [], options \\ []) do
    case columns(connection, statement, params, options) do
      {:ok, columns} -> columns
      {:error, error} -> raise error
    end
  end

  @doc """
  Runs a query and returns a `QuackDB.Columns` struct.

  This preserves column order, original names, row count, and result metadata in
  addition to the column vectors.
  """
  @spec columnar(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, QuackDB.Columns.t()} | {:error, Exception.t()}
  def columnar(connection, statement, params \\ [], options \\ []) do
    case query(connection, statement, params, options) do
      {:ok, result} -> {:ok, QuackDB.Result.to_columnar(result)}
      {:error, _error} = error -> error
    end
  end

  @spec columnar!(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: QuackDB.Columns.t()
  def columnar!(connection, statement, params \\ [], options \\ []) do
    case columnar(connection, statement, params, options) do
      {:ok, columns} -> columns
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams query results as column-oriented batches.

  Each item is a map from disambiguated column names to the values in that fetch
  batch. This keeps large analytical results vector-shaped without materializing
  the whole result set. Prefer `columnar_batches/4` when you also need batch
  metadata.
  """
  @spec column_batches(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: Enumerable.t()
  def column_batches(connection, statement, params \\ [], options \\ []) do
    connection
    |> columnar_batches(statement, params, options)
    |> Elixir.Stream.map(& &1.columns)
    |> Elixir.Stream.reject(&(&1 == %{}))
  end

  @doc """
  Streams query results as `QuackDB.Columns` batches.

  This uses a columnar cursor path so large analytical results can stay
  vector-shaped instead of being materialized as row lists first.
  """
  @spec columnar_batches(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: Enumerable.t()
  def columnar_batches(connection, statement, params \\ [], options \\ []) do
    options = Keyword.put(options, :result_format, :columnar)

    connection
    |> stream(statement, params, options)
    |> Elixir.Stream.map(&QuackDB.Result.to_columnar/1)
    |> Elixir.Stream.reject(&(&1.names == []))
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

  defp with_connection(connection, options, fun) when is_atom(connection) do
    cond do
      not function_exported?(connection, :__adapter__, 0) ->
        fun.(connection)

      not Code.ensure_loaded?(Ecto.Repo.Registry) or
          not Code.ensure_loaded?(Ecto.Adapters.SQL) ->
        fun.(connection)

      connection.__adapter__() != Ecto.Adapters.QuackDB ->
        raise ArgumentError,
              "expected a QuackDB connection or Ecto.Adapters.QuackDB repo, got: #{inspect(connection)}"

      true ->
        connection.checkout(
          fn ->
            connection
            |> ecto_adapter_meta()
            |> checked_out_ecto_connection()
            |> fun.()
          end,
          options
        )
    end
  end

  defp with_connection(connection, _options, fun), do: fun.(connection)

  defp ecto_adapter_meta(repo) do
    repo.get_dynamic_repo()
    |> then(&apply(Ecto.Repo.Registry, :lookup, [&1]))
  end

  defp checked_out_ecto_connection(%{pid: pool}) do
    case Process.get({Ecto.Adapters.SQL, pool}) do
      nil -> raise ArgumentError, "Ecto repo checkout did not provide a QuackDB connection"
      :undefined -> raise ArgumentError, "Ecto repo checkout did not provide a QuackDB connection"
      connection -> connection
    end
  end

  defp result_maps(%QuackDB.Result{columns: columns, rows: rows})
       when is_list(columns) and is_list(rows) do
    map_keys = QuackDB.Result.disambiguate_columns(columns)
    Enum.map(rows, fn row -> map_keys |> Enum.zip(row) |> Map.new() end)
  end

  defp result_maps(_result), do: []
end

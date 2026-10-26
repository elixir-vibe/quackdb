defmodule QuackDB do
  @moduledoc """
  DuckDB for Elixir applications: the DBConnection client.

  Queries, streams, transactions, and native appends over DuckDB's Quack
  protocol (version 3, served by DuckDB 2.0). `QuackDB.Server` supervises a
  local DuckDB process, and `Ecto.Adapters.QuackDB` puts Ecto on top of this
  client.

  ## Connection options

    * `:uri` and `:token` locate and authenticate the Quack server.
    * `:heartbeat_timeout` is the connection lease in seconds the client asks
      for (default `60`). The server drops a connection that sends no request
      for that long; DBConnection's idle pings send heartbeats, so only a
      connection checked out and left unused for longer can expire. An
      expired connection reconnects.
    * `:client_id` identifies this client in the server's logs.
    * `:acknowledge_results` confirms every fully received result, so a
      server with `quack_enable_reconnects` drops its cached copy right away
      instead of waiting for `quack_result_ttl`.
    * `:fetch_retries` is how often a result batch is requested again after
      its HTTP connection broke (default `1`). Batches are numbered, so a
      retry never skips or repeats rows.
    * `:copy_binaries` copies decoded strings and blobs off the HTTP response
      (default `false`); it can also be passed per query. Without it, a
      decoded string of 64 bytes or more is a slice of the response it
      arrived in, so keeping it keeps the whole response, up to one result
      batch, in memory. Copying about doubles decode time for string columns
      and costs nothing for other columns. Use it when you keep a few values
      from large results, for example in a cache or a long-lived process.
    * `:connect_timeout`, `:receive_timeout`, `:shutdown_timeout`, and
      `:mint_options` tune the HTTP transport.

  Query options include `:inline_rows`, the number of rows the server may
  return with the first response before the rest is fetched in batches.
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
          | {:heartbeat_timeout, pos_integer()}
          | {:client_id, String.t()}
          | {:acknowledge_results, boolean()}
          | {:fetch_retries, non_neg_integer()}
          | {:copy_binaries, boolean()}
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
  Appends row-oriented values to a DuckDB table by streaming binary vectors into an `INSERT`.

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

  Declare VARIANT columns as `:variant`, so each value keeps its own shape,
  and JSON columns as `:json`.

  Options:

    * `:columns` - `[{name, type}]` column types, also naming the inserted
      columns. Omitted table columns get their defaults.
    * `:schema` - the table's schema, or a nested schema path as a list.
    * `:batch_size` - rows per request; requests carry vectors of at most
      2048 rows.
    * `:on_conflict` - `:raise` (default), `:nothing`, or `{:nothing, targets}`.
    * `:returning` - columns to return; the result then carries those rows.
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
  Appends column-oriented values to a DuckDB table by streaming binary vectors into an `INSERT`.

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
    |> drop_trailing_empty_batches()
  end

  # The server can report more batches until its stream ends cleanly, which
  # leaves an empty final fetch. An empty result still yields one batch.
  defp drop_trailing_empty_batches(batches),
    do: Elixir.Stream.transform(batches, :first, &drop_trailing_empty_batch/2)

  defp drop_trailing_empty_batch(%QuackDB.Columns{num_rows: 0}, :emitted), do: {[], :emitted}
  defp drop_trailing_empty_batch(batch, _state), do: {[batch], :emitted}

  @doc """
  Interrupts the query running on the remote connection `connection_id`.

  Run it from another process than the one waiting on the query. The
  connection id appears in every `QuackDB.Result`, `QuackDB.Error`, and
  `[:quackdb, :query, :start]` telemetry event, including those of Ecto
  queries, and a query interrupted this way fails with a `:query_cancelled`
  error:

      :telemetry.attach("report-connection", [:quackdb, :query, :start], fn _event, _measurements, metadata, parent ->
        send(parent, {:running, metadata.connection_id})
      end, self())

      task = Task.async(fn -> MyApp.AnalyticsRepo.all(yearly_report) end)

      receive do
        {:running, connection_id} -> QuackDB.cancel("http://[::1]:9494", connection_id)
      end

      Task.await(task)
      #=> ** (QuackDB.Error) Interrupted: query was cancelled

  Pass `query_uuid: uuid` to cancel only that query. Transport timeouts and
  disconnects already cancel their query on the server.
  """
  @spec cancel(String.t() | URI.t(), String.t(), Keyword.t()) :: :ok | {:error, Exception.t()}
  defdelegate cancel(uri, connection_id, options \\ []), to: QuackDB.DBConnection

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

defmodule QuackDB.DBConnection do
  @moduledoc """
  DBConnection implementation for the remote DuckDB Quack protocol.

  This module owns connection lifecycle, request execution, cursor-based streaming, transaction callbacks, and result normalization. HTTP transport and binary protocol encoding are delegated so the codec remains independent from DBConnection.
  """

  use DBConnection

  import QuackDB.SQL.Fragment,
    only: [column: 1, insert_columns: 1, on_conflict: 1, returning: 1, table: 1]

  alias QuackDB.Error
  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Disconnect
  alias QuackDB.Protocol.Message.Acknowledgement
  alias QuackDB.Protocol.Message.CancelRequest
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.FetchRequest
  alias QuackDB.Protocol.Message.FetchResponse
  alias QuackDB.Protocol.Message.HeartbeatRequest
  alias QuackDB.Protocol.Message.PrepareRequest
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message.PrepareResponse
  alias QuackDB.Protocol.Message.SendDataRequest
  alias QuackDB.Protocol.Message.SendDataResponse
  alias QuackDB.Protocol.Message.SuccessResponse
  alias QuackDB.Query
  alias QuackDB.Result
  alias QuackDB.Telemetry

  @disconnect_timeout 1_000
  # The server hands each streamed chunk to the INSERT pipeline as is, so a
  # chunk must not exceed DuckDB's standard vector size.
  @max_chunk_rows 2048
  @default_heartbeat_timeout 60
  @default_fetch_retries 1
  @sql_command_atoms ~w(
    alter analyze attach begin call checkpoint commit copy create delete detach drop explain insert
    install load pragma rollback select set summarize truncate update use vacuum
  )a
  @sql_command_map Map.new(@sql_command_atoms, &{Atom.to_string(&1), &1})
  @sql_command_aliases %{"from" => :select, "values" => :select}

  defstruct [
    :uri,
    :token,
    :connection_id,
    :server,
    :transport,
    :transport_owner,
    :transport_options,
    :client_version,
    :client_id,
    :telemetry_prefix,
    heartbeat_timeout: @default_heartbeat_timeout,
    acknowledge_results?: false,
    copy_binaries?: false,
    next_query_id: 1,
    status: :idle,
    cursors: %{}
  ]

  @type state :: %__MODULE__{
          uri: URI.t(),
          token: String.t(),
          connection_id: String.t() | nil,
          server: ConnectionResponse.t() | nil,
          transport: function(),
          transport_owner: pid() | nil,
          transport_options: keyword(),
          client_version: String.t(),
          client_id: String.t(),
          telemetry_prefix: [atom()],
          heartbeat_timeout: pos_integer(),
          acknowledge_results?: boolean(),
          copy_binaries?: boolean(),
          next_query_id: pos_integer(),
          status: DBConnection.status(),
          cursors: map()
        }

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    DBConnection.start_link(__MODULE__, options)
  end

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(options) do
    DBConnection.child_spec(__MODULE__, options)
  end

  @impl true
  def connect(options) do
    with {:ok, state} <- build_state(options),
         {:ok, state} <- connect_quack(state) do
      {:ok, state}
    end
  end

  @impl true
  def checkout(state), do: {:ok, state}

  @impl true
  def ping(state) do
    case state |> request(%HeartbeatRequest{}, []) |> expect(SuccessResponse) do
      {:ok, _response} -> {:ok, state}
      {:error, error} -> {:disconnect, error, state}
    end
  end

  @impl true
  def handle_prepare(%Query{operation: nil} = query, _options, state) do
    {:ok, %{query | statement: IO.iodata_to_binary(query.statement)}, state}
  end

  def handle_prepare(%Query{} = query, _options, state), do: {:ok, query, state}

  @impl true
  def handle_execute(
        %Query{operation: {:insert_rows, table, rows, insert_options}} = query,
        params,
        options,
        state
      ) do
    if params == [] do
      query
      |> append_rows(table, rows, Keyword.merge(insert_options, options), state)
      |> disconnect_on_fatal()
    else
      {:error,
       Error.new(:unsupported_params, "append queries do not accept params", source: :client),
       state}
    end
  end

  def handle_execute(
        %Query{operation: {:insert_columns, table, columns, insert_options}} = query,
        params,
        options,
        state
      ) do
    if params == [] do
      query
      |> append_columns(table, columns, Keyword.merge(insert_options, options), state)
      |> disconnect_on_fatal()
    else
      {:error,
       Error.new(:unsupported_params, "append queries do not accept params", source: :client),
       state}
    end
  end

  def handle_execute(%Query{} = query, params, options, state) do
    query |> execute_statement(params, options, state) |> disconnect_on_fatal()
  end

  @impl true
  def handle_close(_query, _options, state) do
    {:ok, empty_result(:close), state}
  end

  @impl true
  def handle_begin(_options, %{status: :idle} = state) do
    transaction_statement("BEGIN", :begin, :transaction, state)
  end

  def handle_begin(_options, state), do: {state.status, state}

  @impl true
  def handle_commit(_options, %{status: :transaction} = state) do
    transaction_statement("COMMIT", :commit, :idle, state)
  end

  def handle_commit(_options, state), do: {state.status, state}

  @impl true
  def handle_rollback(_options, %{status: status} = state)
      when status in [:transaction, :error] do
    transaction_statement("ROLLBACK", :rollback, :idle, state)
  end

  def handle_rollback(_options, state), do: {state.status, state}

  @impl true
  def handle_status(_options, state), do: {state.status, state}

  @impl true
  def handle_declare(%Query{} = query, params, options, state) do
    query |> declare_query(params, options, state) |> disconnect_on_fatal()
  end

  @impl true
  def handle_fetch(_query, %QuackDB.Cursor{} = cursor, options, state) do
    cursor_state = Map.fetch!(state.cursors, cursor.ref)

    result =
      if cursor_state.mode == :columnar do
        handle_fetch_columnar(cursor_state, cursor, options, state)
      else
        handle_fetch_rows(cursor_state, cursor, options, state)
      end

    disconnect_on_fatal(result)
  end

  @impl true
  def handle_deallocate(_query, %QuackDB.Cursor{} = cursor, _options, state) do
    {:ok, cursor_result(cursor, []), %{state | cursors: Map.delete(state.cursors, cursor.ref)}}
  end

  @impl true
  def disconnect(_error, %{connection_id: nil}), do: :ok

  # DBConnection disconnects on timeouts while the query may still run, and
  # the pooled transport may still be waiting on it. Cancel and disconnect
  # over a fresh HTTP connection so the server stops the query either way.
  def disconnect(_error, state) do
    options = [timeout: @disconnect_timeout]
    _ignored = side_request(state, %CancelRequest{}, options)
    _ignored = side_request(state, %Disconnect{}, options)

    if state.transport_owner do
      stop_transport(state.transport_owner)
    end

    :ok
  end

  @doc false
  @spec cancel(String.t() | URI.t(), String.t(), Keyword.t()) :: :ok | {:error, Error.t()}
  def cancel(uri, connection_id, options \\ []) when is_binary(connection_id) do
    message = %CancelRequest{query_uuid: Keyword.get(options, :query_uuid, 0)}

    with {:ok, uri} <- normalize_uri(uri),
         state = %__MODULE__{uri: uri, connection_id: connection_id, transport: &one_shot_post/3},
         {:ok, _response} <-
           state |> request(message, transport_options(options)) |> expect(SuccessResponse) do
      :ok
    end
  end

  defp normalize_uri(%URI{} = uri), do: {:ok, uri}
  defp normalize_uri(uri) when is_binary(uri), do: QuackDB.URI.normalize(uri)

  defp one_shot_post(uri, body, options), do: QuackDB.Transport.post(uri, body, options)

  defp side_request(%{transport_owner: nil} = state, message, options),
    do: request(state, message, options)

  defp side_request(state, message, options) do
    transport_options = state.transport_options

    post = fn uri, body, options ->
      one_shot_post(uri, body, Keyword.merge(transport_options, options))
    end

    request(%{state | transport: post}, message, options)
  end

  defp stop_transport(owner) do
    GenServer.stop(owner, :normal, @disconnect_timeout)
  catch
    :exit, _reason -> Process.exit(owner, :kill)
  end

  defp disconnect_on_fatal({:error, %Error{} = error, state}) do
    if Error.disconnect?(error), do: {:disconnect, error, state}, else: {:error, error, state}
  end

  defp disconnect_on_fatal(result), do: result

  # A timed-out request leaves its query running on the server; the closed
  # HTTP connection reconnects for the cancel. Returns the result unchanged.
  defp cancel_on_timeout(
         {:error, %Error{metadata: %{reason: :timeout}}} = result,
         query_uuid,
         state,
         options
       ) do
    _ignored = request(state, %CancelRequest{query_uuid: query_uuid}, options)
    result
  end

  defp cancel_on_timeout(result, _query_uuid, _state, _options), do: result

  # Sends one message and returns its decoded reply with the timing and size
  # metrics telemetry reports. Server error responses become QuackDB errors.
  defp exchange(state, message, options) do
    {encode_duration, request} = timed(fn -> encode_request(message, state, options) end)

    {transport_duration, transport_result} =
      timed(fn -> state.transport.(state.uri, request, options) end)

    metrics = %{
      encode_duration: encode_duration,
      transport_duration: transport_duration,
      request_bytes: IO.iodata_length(request)
    }

    case transport_result do
      {:ok, response} ->
        copy? = Keyword.get(options, :copy_binaries, state.copy_binaries?)
        {decode_duration, result} = timed(fn -> decode_reply(response, copy?) end)

        {result,
         metrics
         |> Map.put(:decode_duration, decode_duration)
         |> Map.put(:response_bytes, byte_size(response))}

      {:error, _error} = error ->
        {error, metrics}
    end
  end

  defp request(state, message, options) do
    {result, _metrics} = exchange(state, message, options)
    result
  end

  defp encode_request(message, state, options) do
    Codec.encode(message,
      connection_id: state.connection_id,
      client_query_id: Keyword.get(options, :client_query_id)
    )
  end

  defp decode_reply(response, copy?) do
    case Codec.decode(response) do
      {:ok, {_header, %ErrorResponse{} = error}} -> {:error, Error.server(error)}
      {:ok, {header, message}} when copy? -> {:ok, {header, Codec.copy_binaries(message)}}
      result -> result
    end
  end

  defp expect({:ok, {_header, %module{} = message}}, module), do: {:ok, message}
  defp expect({:ok, {header, _message}}, module), do: {:error, unexpected_message(module, header)}
  defp expect({:error, _error} = error, _module), do: error

  defp unexpected_message(module, header) do
    expected =
      module |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", " ")

    Error.new(:unexpected_message, "expected #{expected}, got #{header.type}", source: :protocol)
  end

  defp failure(error, query, state) do
    {:error, annotate_error(error, query, state), %{state | status: failed_status(state.status)}}
  end

  defp declare_query(%Query{} = query, params, options, state) do
    with {:ok, statement} <- QuackDB.SQL.format(query.statement, params) do
      do_declare_query(query, statement, options, state)
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp do_declare_query(%Query{} = query, statement, options, state) do
    {query_id, state} = next_query_id(state)
    options = Keyword.put(options, :client_query_id, query_id)

    message = %PrepareRequest{
      sql_query: statement,
      query_uuid: new_query_uuid(),
      inline_rows:
        Keyword.get_lazy(options, :inline_rows, fn -> Keyword.get(options, :max_rows, 500) end)
    }

    prepared =
      state
      |> request(message, options)
      |> expect(PrepareResponse)
      |> cancel_on_timeout(message.query_uuid, state, options)

    case prepared do
      {:ok, response} ->
        {query, cursor, cursor_state} = declared_cursor(response, query, options, state)
        {:ok, query, cursor, put_cursor_state(state, cursor.ref, cursor_state)}

      {:error, error} ->
        failure(error, query, state)
    end
  end

  defp declared_cursor(%PrepareResponse{} = response, query, options, state) do
    query = %{
      query
      | columns: response.result_names,
        result_types: response.result_types,
        query_uuid: response.query_uuid
    }

    cursor = %QuackDB.Cursor{
      ref: make_ref(),
      query_uuid: response.query_uuid,
      columns: response.result_names,
      result_types: response.result_types,
      connection_id: state.connection_id,
      statement: query.statement
    }

    queue =
      if Keyword.get(options, :result_format) == :columnar,
        do: %{mode: :columnar, queued_chunks: response.results},
        else: %{
          mode: :rows,
          queued_rows: materialize_rows(response.results, response.result_names)
        }

    {query, cursor, Map.merge(queue, %{next_batch: 1, done?: not response.needs_more_fetch})}
  end

  defp append_rows(%Query{} = query, table, rows, options, state) do
    with {:ok, columns} <- DataChunk.columns_from_rows(rows, options),
         {:ok, batches} <- append_batches(rows, options) do
      options = Keyword.put(options, :columns, columns)
      build_chunk = &DataChunk.from_rows(&1, options)

      send_data_append(
        query,
        table,
        columns,
        length(rows),
        {batches, build_chunk},
        options,
        state
      )
    else
      {:error, error} -> failure(error, query, state)
    end
  end

  defp append_columns(%Query{} = query, table, columns, options, state) do
    with {:ok, row_count} <- column_row_count(columns, options),
         {:ok, resolved} <- DataChunk.columns_from_column_values(columns, options),
         {:ok, batches} <- append_column_batches(columns, row_count, options) do
      options = Keyword.put(options, :columns, resolved)
      build_chunk = &DataChunk.from_columns(&1, options)
      send_data_append(query, table, resolved, row_count, {batches, build_chunk}, options, state)
    else
      {:error, error} -> failure(error, query, state)
    end
  end

  defp append_batches([], options) do
    case Keyword.get(options, :batch_size, 1) do
      batch_size when is_integer(batch_size) and batch_size >= 1 -> {:ok, [[]]}
      _batch_size -> invalid_batch_size()
    end
  end

  defp append_batches(rows, options) do
    row_count = length(rows)
    batch_size = Keyword.get(options, :batch_size, row_count)

    cond do
      not (is_integer(batch_size) and batch_size >= 1) -> invalid_batch_size()
      batch_size >= row_count -> {:ok, [rows]}
      true -> {:ok, Enum.chunk_every(rows, batch_size)}
    end
  end

  defp invalid_batch_size do
    {:error,
     Error.new(:invalid_batch_size, "append batch_size must be a positive integer",
       source: :client
     )}
  end

  defp column_row_count(columns, _options) do
    columns
    |> Enum.map(fn
      {_name, values} when is_list(values) ->
        {:ok, length(values)}

      {name, values} ->
        {:error,
         Error.new(
           :invalid_append_column,
           "column #{inspect(name)} values must be a list, got #{inspect(values)}",
           source: :client
         )}

      value ->
        {:error,
         Error.new(:invalid_append_column, "invalid append column values #{inspect(value)}",
           source: :client
         )}
    end)
    |> collect_column_counts()
  end

  defp collect_column_counts(counts) do
    Enum.reduce_while(counts, {:ok, []}, fn
      {:ok, count}, {:ok, counts} -> {:cont, {:ok, [count | counts]}}
      {:error, _error} = error, {:ok, _counts} -> {:halt, error}
    end)
    |> case do
      {:ok, []} ->
        {:error,
         Error.new(
           :missing_append_columns,
           "cannot infer append row count from an empty column set",
           source: :client
         )}

      {:ok, counts} ->
        case Enum.uniq(counts) do
          [row_count] ->
            {:ok, row_count}

          counts ->
            {:error,
             Error.new(
               :invalid_vector_size,
               "append columns have mismatched row counts #{inspect(counts)}",
               source: :client
             )}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp append_column_batches(columns, 0, options) do
    case Keyword.get(options, :batch_size, 1) do
      batch_size when is_integer(batch_size) and batch_size >= 1 -> {:ok, [columns]}
      _batch_size -> invalid_batch_size()
    end
  end

  defp append_column_batches(columns, row_count, options) do
    batch_size = Keyword.get(options, :batch_size, row_count)

    cond do
      not (is_integer(batch_size) and batch_size >= 1) ->
        invalid_batch_size()

      batch_size >= row_count ->
        {:ok, [columns]}

      true ->
        {:ok, columns |> Enum.map(&chunk_column(&1, batch_size)) |> transpose_column_batches()}
    end
  end

  defp chunk_column({name, values}, batch_size), do: {name, Enum.chunk_every(values, batch_size)}

  defp transpose_column_batches(chunked_columns) do
    names = Enum.map(chunked_columns, &elem(&1, 0))

    chunked_columns
    |> Enum.map(&elem(&1, 1))
    |> Enum.zip()
    |> Enum.map(fn chunks -> Enum.zip(names, Tuple.to_list(chunks)) end)
  end

  # Appends stream through `scan_data_from_quack_client`: an INSERT that reads
  # a client stream is prepared without inline rows, the batches follow as
  # send-data requests, a terminal request closes the stream against its batch
  # count, and the INSERT's own result (a row count or RETURNING rows) is
  # fetched like any other result.
  defp send_data_append(query, table, columns, row_count, {batches, build_chunk}, options, state) do
    {query_id, state} = next_query_id(state)
    options = Keyword.put(options, :client_query_id, query_id)
    metadata = append_metadata(query, table, row_count, batches, options, state)

    Telemetry.span(state.telemetry_prefix, :append, metadata, fn ->
      append_started_at = System.monotonic_time()

      {result, append_metrics} =
        case stream_append(table, columns, {batches, build_chunk}, options, state) do
          {:ok, result, metrics} ->
            {{:ok, query, result, %{state | status: successful_status(state.status)}}, metrics}

          {:error, error, metrics} ->
            {failure(error, query, state), metrics}
        end

      append_duration = System.monotonic_time() - append_started_at
      {result, append_stop_metadata(result, append_metrics, append_duration)}
    end)
  end

  defp stream_append(table, columns, {batches, build_chunk}, options, state) do
    stream_id = new_stream_id()
    query_uuid = new_query_uuid()

    prepare = %PrepareRequest{
      sql_query: send_data_statement(table, columns, stream_id, options),
      query_uuid: query_uuid,
      inline_rows: 0
    }

    with {:ok, prepared} <- state |> request(prepare, options) |> expect(PrepareResponse),
         {:ok, metrics} <- send_batches(stream_id, batches, build_chunk, options, state),
         {:ok, chunks} <- fetch_remaining_chunks(prepared, state, options) do
      {:ok, append_result(prepared, chunks, options, state), metrics}
    else
      {:error, error} ->
        _ignored = request(state, %CancelRequest{query_uuid: query_uuid}, options)
        {:error, error, empty_append_metrics()}
    end
  end

  defp send_data_statement(table, columns, stream_id, options) do
    names = Enum.map(columns, & &1.name)

    prototype =
      columns
      |> Enum.map(&[column(&1.name), " ", LogicalType.to_sql(&1.type)])
      |> Enum.intersperse(", ")

    [
      "INSERT INTO ",
      table({Keyword.get(options, :schema), table}),
      insert_columns(names),
      " SELECT * FROM scan_data_from_quack_client(",
      QuackDB.SQL.literal!(stream_id),
      ", NULL::STRUCT(",
      prototype,
      "))",
      on_conflict(Keyword.get(options, :on_conflict, :raise)),
      returning(Keyword.get(options, :returning, []))
    ]
    |> IO.iodata_to_binary()
  end

  defp send_batches(stream_id, batches, build_chunk, options, state) do
    batches
    |> Enum.reduce_while({:ok, empty_append_metrics(), 0}, fn batch, {:ok, metrics, sent} ->
      case send_batch(stream_id, batch, sent + 1, build_chunk, options, state) do
        {:ok, :empty} ->
          {:cont, {:ok, metrics, sent}}

        {:ok, batch_metrics} ->
          {:cont, {:ok, merge_append_metrics(metrics, batch_metrics), sent + 1}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, metrics, sent} ->
        terminal = %SendDataRequest{stream_id: stream_id, total_batches: sent}

        with {:ok, _terminal_metrics} <- send_data(terminal, 0, state, options) do
          {:ok, metrics}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp send_batch(stream_id, batch, batch_index, build_chunk, options, state) do
    case timed(fn -> build_chunk.(batch) end) do
      {_build_duration, {:ok, %{row_count: 0}}} ->
        {:ok, :empty}

      {build_duration, {:ok, chunk}} ->
        message = %SendDataRequest{
          stream_id: stream_id,
          batch_index: batch_index,
          chunks: DataChunk.split(chunk, @max_chunk_rows)
        }

        send_data(message, build_duration, state, options)

      {_build_duration, {:error, _error} = error} ->
        error
    end
  end

  # Building the chunk counts as encoding in append telemetry.
  defp send_data(message, build_duration, state, options) do
    {result, metrics} = exchange(state, message, options)

    with {:ok, _response} <- expect(result, SendDataResponse) do
      {:ok,
       metrics |> Map.update!(:encode_duration, &(&1 + build_duration)) |> Map.put(:batches, 1)}
    end
  end

  defp empty_append_metrics do
    %{
      batches: 0,
      encode_duration: 0,
      transport_duration: 0,
      decode_duration: 0,
      request_bytes: 0,
      response_bytes: 0
    }
  end

  defp merge_append_metrics(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value -> left_value + right_value end)
  end

  defp timed(fun) do
    started_at = System.monotonic_time()
    result = fun.()
    {System.monotonic_time() - started_at, result}
  end

  # A prepare without inline rows answers before the INSERT binds its result,
  # so the server cannot name the columns yet: they are DuckDB's `Count`, or
  # the requested RETURNING columns.
  defp append_result(%PrepareResponse{} = response, chunks, options, state) do
    columns =
      case Keyword.get(options, :returning, []) do
        [] -> ["Count"]
        returning -> Enum.map(returning, &to_string/1)
      end

    %Result{
      command: :insert,
      columns: columns,
      rows: materialize_rows(response.results ++ chunks, columns),
      connection_id: state.connection_id,
      messages: [],
      metadata: %{query_uuid: response.query_uuid}
    }
    |> then(&%{&1 | num_rows: length(&1.rows)})
    |> Result.normalize()
  end

  defp new_stream_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp execute_statement(%Query{} = query, params, options, state) do
    with {:ok, statement} <- QuackDB.SQL.format(query.statement, params) do
      do_execute_statement(query, statement, params, options, state)
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp do_execute_statement(%Query{} = query, statement, params, options, state) do
    {query_id, state} = next_query_id(state)
    options = Keyword.put(options, :client_query_id, query_id)

    message = %PrepareRequest{
      sql_query: statement,
      query_uuid: new_query_uuid(),
      inline_rows: Keyword.get(options, :inline_rows)
    }

    Telemetry.span(
      state.telemetry_prefix,
      :query,
      query_metadata(query, params, options, state),
      fn ->
        {result, metrics} = exchange(state, message, options)

        {normalize_duration, result} =
          timed(fn ->
            with {:ok, response} <-
                   result
                   |> expect(PrepareResponse)
                   |> cancel_on_timeout(message.query_uuid, state, options) do
              query_result(response, query, state, options)
            end
          end)

        result =
          case result do
            {:ok, query, result} ->
              {:ok, query, result, %{state | status: successful_status(state.status)}}

            {:error, error} ->
              failure(error, query, state)
          end

        {result,
         query_stop_metadata(result, Map.put(metrics, :normalize_duration, normalize_duration))}
      end
    )
  end

  # Fetches the rest of the result and builds the row-oriented result.
  defp query_result(%PrepareResponse{} = response, query, state, options) do
    with {:ok, chunks} <- fetch_remaining_chunks(response, state, options) do
      rows = materialize_rows(response.results ++ chunks, response.result_names)

      query = %{
        query
        | columns: response.result_names,
          result_types: response.result_types,
          query_uuid: response.query_uuid
      }

      result =
        Result.normalize(%Result{
          command: command(query.statement),
          columns: response.result_names,
          rows: rows,
          num_rows: length(rows),
          connection_id: state.connection_id,
          messages: [],
          metadata: %{
            needs_more_fetch: response.needs_more_fetch,
            query_uuid: response.query_uuid
          }
        })

      {:ok, query, result}
    end
  end

  defp fetch_remaining_chunks(
         %PrepareResponse{needs_more_fetch: false} = response,
         state,
         options
       ) do
    with :ok <- acknowledge(response.query_uuid, state, options), do: {:ok, []}
  end

  defp fetch_remaining_chunks(%PrepareResponse{} = response, state, options) do
    with {:ok, chunks} <- fetch_all_batches(response.query_uuid, 1, state, options, []),
         :ok <- acknowledge(response.query_uuid, state, options) do
      {:ok, chunks}
    end
  end

  defp fetch_all_batches(query_uuid, batch_index, state, options, chunks) do
    case fetch_batch(query_uuid, batch_index, state, options) do
      {:ok, {:batch, batch}} ->
        fetch_all_batches(
          query_uuid,
          batch_index + 1,
          state,
          options,
          Enum.reverse(batch, chunks)
        )

      {:ok, :done} ->
        {:ok, Enum.reverse(chunks)}

      {:error, _error} = error ->
        error
    end
  end

  # Fetches one dense batch. `ack_index` tells the server every earlier batch
  # arrived, so it can drop them; a retry of the same index gets the same batch.
  defp fetch_batch(query_uuid, batch_index, state, options) do
    Telemetry.span(
      state.telemetry_prefix,
      :fetch,
      fetch_metadata(query_uuid, batch_index, options, state),
      fn ->
        message = %FetchRequest{
          query_uuid: query_uuid,
          batch_index: batch_index,
          ack_index: batch_index - 1
        }

        retries = Keyword.get(options, :fetch_retries, @default_fetch_retries)
        {result, metrics} = exchange_with_retries(state, message, options, retries)

        {normalize_duration, result} =
          timed(fn ->
            with {:ok, response} <- expect(result, FetchResponse),
                 do: fetched_batch(response, batch_index)
          end)

        result = cancel_on_timeout(result, query_uuid, state, options)

        {result,
         fetch_stop_metadata(result, Map.put(metrics, :normalize_duration, normalize_duration))}
      end
    )
  end

  # The server keeps a served batch until a later request acknowledges it, so
  # a fetch that lost its HTTP connection can ask for the same batch again.
  defp exchange_with_retries(state, message, options, retries) do
    case exchange(state, message, options) do
      {{:error, %Error{source: :transport, metadata: %{reason: reason}}}, _metrics}
      when retries > 0 and reason != :timeout ->
        exchange_with_retries(state, message, options, retries - 1)

      exchange ->
        exchange
    end
  end

  defp fetched_batch(%FetchResponse{results: []} = response, batch_index) do
    case response.total_batches do
      total when total in [nil, batch_index - 1] ->
        {:ok, :done}

      total ->
        {:error,
         Error.new(
           :incomplete_result,
           "server reported #{total} result batches but the client received #{batch_index - 1}",
           source: :protocol
         )}
    end
  end

  defp fetched_batch(%FetchResponse{} = response, batch_index) do
    if response.batch_index in [nil, batch_index] do
      {:ok, {:batch, response.results}}
    else
      {:error,
       Error.new(
         :unexpected_batch,
         "requested result batch #{batch_index}, got #{response.batch_index}",
         source: :protocol
       )}
    end
  end

  # With reconnects enabled the server keeps the last result until the client
  # confirms it arrived. A failed acknowledgement does not fail the query.
  defp acknowledge(_query_uuid, %{acknowledge_results?: false}, _options), do: :ok

  defp acknowledge(query_uuid, state, options) do
    _ignored = request(state, %Acknowledgement{query_uuid: query_uuid}, options)
    :ok
  end

  defp handle_fetch_rows(cursor_state, cursor, options, state) do
    cond do
      cursor_state.queued_rows != [] ->
        {rows, cursor_state} =
          take_cursor_rows(cursor_state, Keyword.get(options, :max_rows, 500))

        status = if cursor_state.done? and cursor_state.queued_rows == [], do: :halt, else: :cont
        state = put_cursor_state(state, cursor.ref, cursor_state)
        {status, cursor_result(cursor, rows), state}

      cursor_state.done? ->
        {:halt, cursor_result(cursor, []), state}

      true ->
        fetch_more_cursor_rows(cursor_state, cursor, options, state)
    end
  end

  defp fetch_more_cursor_rows(cursor_state, cursor, options, state) do
    with {:ok, cursor_state} <- fetch_cursor_state(cursor_state, cursor, options, state) do
      state = put_cursor_state(state, cursor.ref, cursor_state)
      handle_fetch(nil, cursor, options, state)
    else
      {:error, error} -> {:error, annotate_cursor_error(error, cursor), state}
    end
  end

  defp handle_fetch_columnar(cursor_state, cursor, options, state) do
    cond do
      cursor_state.queued_chunks != [] ->
        {chunks, cursor_state} =
          take_cursor_chunks(cursor_state, Keyword.get(options, :max_rows, 500))

        status =
          if cursor_state.done? and cursor_state.queued_chunks == [], do: :halt, else: :cont

        state = put_cursor_state(state, cursor.ref, cursor_state)
        {status, cursor_result(cursor, nil, chunks), state}

      cursor_state.done? ->
        {:halt, cursor_result(cursor, nil, []), state}

      true ->
        fetch_more_cursor_rows(cursor_state, cursor, options, state)
    end
  end

  defp fetch_cursor_state(cursor_state, cursor, options, state) do
    case fetch_batch(cursor.query_uuid, cursor_state.next_batch, state, options) do
      {:ok, :done} ->
        with :ok <- acknowledge(cursor.query_uuid, state, options),
             do: {:ok, %{cursor_state | done?: true}}

      {:ok, {:batch, chunks}} ->
        {:ok,
         queue_cursor_chunks(
           %{cursor_state | next_batch: cursor_state.next_batch + 1},
           chunks,
           cursor
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp queue_cursor_chunks(%{mode: :columnar} = cursor_state, chunks, _cursor) do
    %{cursor_state | queued_chunks: cursor_state.queued_chunks ++ chunks}
  end

  defp queue_cursor_chunks(cursor_state, chunks, cursor) do
    %{
      cursor_state
      | queued_rows: cursor_state.queued_rows ++ materialize_rows(chunks, cursor.columns)
    }
  end

  # Zero is reserved for the server's internal catalog traffic.
  defp new_query_uuid do
    <<_sign::1, uuid::127>> = :crypto.strong_rand_bytes(16)
    if uuid == 0, do: new_query_uuid(), else: uuid
  end

  defp put_cursor_state(state, ref, cursor_state) do
    %{state | cursors: Map.put(state.cursors, ref, cursor_state)}
  end

  defp annotate_error(%Error{} = error, %Query{} = query, state) do
    %Error{error | query: query.statement, connection_id: state.connection_id}
  end

  defp next_query_id(state) do
    {state.next_query_id, %{state | next_query_id: state.next_query_id + 1}}
  end

  defp annotate_cursor_error(%Error{} = error, %QuackDB.Cursor{} = cursor) do
    %Error{error | query: cursor.statement, connection_id: cursor.connection_id}
  end

  defp materialize_rows(chunks, columns) do
    Enum.flat_map(chunks, &DataChunk.rows(&1, columns))
  end

  defp transaction_statement(statement, command, next_status, state) do
    query = %Query{statement: statement}

    case execute_statement(query, [], [], state) do
      {:ok, _query, result, state} ->
        {:ok, %{result | command: command}, %{state | status: next_status}}

      {:error, error, state} ->
        {:disconnect, error, state}
    end
  end

  defp build_state(options) do
    uri = Keyword.get(options, :uri, "http://localhost:9494")

    with {:ok, uri} <- QuackDB.URI.normalize(uri),
         :ok <- validate_heartbeat_timeout(Keyword.get(options, :heartbeat_timeout)) do
      {:ok,
       %__MODULE__{
         uri: uri,
         token: Keyword.get(options, :token, ""),
         transport: Keyword.get(options, :transport),
         transport_owner: nil,
         transport_options: transport_options(options),
         client_version: Keyword.get(options, :client_version, client_version()),
         client_id: Keyword.get(options, :client_id, ""),
         heartbeat_timeout: Keyword.get(options, :heartbeat_timeout, @default_heartbeat_timeout),
         acknowledge_results?: Keyword.get(options, :acknowledge_results, false),
         copy_binaries?: Keyword.get(options, :copy_binaries, false),
         telemetry_prefix: Keyword.get(options, :telemetry_prefix, Telemetry.default_prefix())
       }}
    end
  end

  # DuckDB bounds the lease so that it fits in signed 64-bit milliseconds.
  defp validate_heartbeat_timeout(nil), do: :ok

  defp validate_heartbeat_timeout(seconds)
       when is_integer(seconds) and seconds > 0 and seconds <= div(0x7FFF_FFFF_FFFF_FFFF, 1000),
       do: :ok

  defp validate_heartbeat_timeout(seconds) do
    {:error,
     Error.new(
       :invalid_heartbeat_timeout,
       "expected :heartbeat_timeout to be a positive number of seconds, got: #{inspect(seconds)}",
       source: :client
     )}
  end

  defp connect_quack(state) do
    with {:ok, state} <- start_transport(state) do
      do_connect_quack(state)
    end
  end

  defp do_connect_quack(state) do
    message = %ConnectionRequest{
      auth_string: state.token,
      client_duckdb_version: state.client_version,
      client_platform: client_platform(),
      client_id: state.client_id,
      heartbeat_timeout_seconds: state.heartbeat_timeout
    }

    case request(state, message, []) do
      {:ok, {header, %ConnectionResponse{quack_version: 3} = response}} ->
        {:ok,
         %{
           state
           | connection_id: header.connection_id,
             server: response,
             heartbeat_timeout: response.heartbeat_timeout_seconds
         }}

      {:ok, {_header, %ConnectionResponse{} = response}} ->
        reason = "the server selected Quack protocol version #{response.quack_version}"
        {:error, unsupported_quack_version(reason, response)}

      # A DuckDB 1.5 server cannot parse the version 3 handshake and answers
      # with a bare HTTP 500.
      {:error, %Error{code: :http_error, metadata: %{status: 500}} = error} ->
        {:error, unsupported_quack_version("the server rejected the handshake", error)}

      {:error, %Error{source: :server, message: "Unsupported Quack version" <> _rest} = error} ->
        {:error, unsupported_quack_version(error.message, error)}

      {:ok, {header, _message}} ->
        {:error, unexpected_message(ConnectionResponse, header)}

      {:error, _error} = error ->
        error
    end
  end

  defp unsupported_quack_version(reason, cause) do
    Error.new(
      :unsupported_quack_version,
      "#{reason}; QuackDB requires Quack protocol version 3 (DuckDB 2.0)",
      source: :protocol,
      metadata: %{cause: cause}
    )
  end

  defp start_transport(%{transport: nil, uri: uri} = state) do
    case QuackDB.Transport.start_link(uri, state.transport_options) do
      {:ok, owner} ->
        {:ok,
         %{state | transport: &QuackDB.Transport.post(owner, &1, &2, &3), transport_owner: owner}}

      {:error, reason} ->
        {:error, Error.new(:transport_error, inspect(reason), source: :transport)}
    end
  end

  defp start_transport(%{transport: transport} = state) when is_function(transport, 3),
    do: {:ok, state}

  defp transport_options(options) do
    Keyword.take(options, [:connect_timeout, :receive_timeout, :shutdown_timeout, :mint_options])
  end

  defp take_cursor_rows(cursor, max_rows) do
    {rows, remaining} = Enum.split(cursor.queued_rows, max_rows)
    {rows, %{cursor | queued_rows: remaining}}
  end

  defp take_cursor_chunks(cursor, max_rows) do
    {chunks, remaining, row_count} = take_chunks(cursor.queued_chunks, max_rows, [], 0)
    {chunks, cursor |> Map.put(:queued_chunks, remaining) |> Map.put(:row_count, row_count)}
  end

  defp take_chunks(chunks, remaining_rows, selected, row_count)
       when remaining_rows <= 0 or chunks == [] do
    {Enum.reverse(selected), chunks, row_count}
  end

  defp take_chunks([chunk | chunks], remaining_rows, selected, row_count) do
    if chunk.row_count <= remaining_rows do
      take_chunks(
        chunks,
        remaining_rows - chunk.row_count,
        [chunk | selected],
        row_count + chunk.row_count
      )
    else
      {selected_chunk, remaining_chunk} = DataChunk.split_at(chunk, remaining_rows)

      {Enum.reverse([selected_chunk | selected]), [remaining_chunk | chunks],
       row_count + remaining_rows}
    end
  end

  defp cursor_result(cursor, rows) do
    %Result{
      command: :fetch,
      columns: cursor.columns,
      rows: rows,
      num_rows: length(rows),
      connection_id: cursor.connection_id,
      messages: []
    }
  end

  defp cursor_result(cursor, nil, chunks) do
    %Result{
      command: :fetch,
      columns: cursor.columns,
      rows: nil,
      num_rows: Enum.reduce(chunks, 0, &(&2 + &1.row_count)),
      connection_id: cursor.connection_id,
      messages: [],
      metadata: %{columnar_chunks: chunks}
    }
  end

  defp empty_result(command) do
    %Result{command: command, columns: nil, rows: nil, num_rows: 0, messages: []}
  end

  defp query_metadata(query, params, options, state) do
    options
    |> metadata_from_options(state)
    |> Map.put(:query, query.statement)
    |> maybe_put_params(params, options)
  end

  defp append_metadata(query, table, values, batches, options, state) when is_list(values) do
    append_metadata(query, table, length(values), batches, options, state)
  end

  defp append_metadata(query, table, row_count, batches, options, state) do
    options
    |> metadata_from_options(state)
    |> Map.merge(%{
      query: query.statement,
      table: to_string(table),
      schema: Keyword.get(options, :schema, ""),
      batch_size: Keyword.get(options, :batch_size),
      batches: length(batches),
      rows: row_count
    })
  end

  defp fetch_metadata(query_uuid, batch_index, options, state) do
    options
    |> metadata_from_options(state)
    |> Map.put(:query_uuid, query_uuid)
    |> Map.put(:batch_index, batch_index)
  end

  defp metadata_from_options(options, state) do
    %{
      connection_id: state.connection_id,
      client_query_id: Keyword.get(options, :client_query_id),
      options: Keyword.get(options, :telemetry_options, [])
    }
  end

  defp maybe_put_params(metadata, params, options) do
    if Keyword.get(options, :telemetry_params, false) do
      Map.put(metadata, :params, params)
    else
      metadata
    end
  end

  defp result_stop_metadata({:ok, _query, %Result{} = result, _state}) do
    %{command: result.command, rows: result.num_rows, result: :ok}
  end

  defp result_stop_metadata({:error, %Error{} = error, _state}) do
    %{error: error, result: :error}
  end

  defp query_stop_metadata(result, metrics) do
    result
    |> result_stop_metadata()
    |> Map.merge(metrics)
  end

  defp append_stop_metadata(result, metrics, duration) do
    result
    |> result_stop_metadata()
    |> Map.merge(metrics)
    |> Map.put(:append_duration, duration)
    |> maybe_put_rows_per_second(result, duration)
  end

  defp maybe_put_rows_per_second(
         metadata,
         {:ok, _query, %Result{num_rows: rows}, _state},
         duration
       )
       when is_integer(rows) and rows >= 0 and duration > 0 do
    seconds = System.convert_time_unit(duration, :native, :microsecond) / 1_000_000
    Map.put(metadata, :rows_per_second, rows / seconds)
  end

  defp maybe_put_rows_per_second(metadata, _result, _duration), do: metadata

  defp fetch_stop_metadata({:ok, {:batch, chunks}}, metrics) do
    %{chunks: length(chunks), result: :ok}
    |> Map.merge(metrics)
  end

  defp fetch_stop_metadata({:ok, :done}, metrics) do
    %{chunks: 0, result: :ok}
    |> Map.merge(metrics)
  end

  defp fetch_stop_metadata({:error, %Error{} = error}, metrics) do
    %{error: error, result: :error}
    |> Map.merge(metrics)
  end

  defp command(statement) do
    statement
    |> IO.iodata_to_binary()
    |> first_sql_word()
    |> String.downcase()
    |> sql_command_atom()
  end

  defp sql_command_atom(word) do
    Map.get(@sql_command_map, word) || Map.get(@sql_command_aliases, word, :unknown)
  end

  defp first_sql_word(statement) do
    statement
    |> skip_leading_whitespace()
    |> take_until_whitespace()
  end

  defp skip_leading_whitespace(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r, ?\f] do
    skip_leading_whitespace(rest)
  end

  defp skip_leading_whitespace(rest), do: rest

  defp take_until_whitespace(statement), do: take_until_whitespace(statement, [])

  defp take_until_whitespace(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_until_whitespace(<<char, _rest::binary>>, acc)
       when char in [?\s, ?\t, ?\n, ?\r, ?\f] do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp take_until_whitespace(<<char, rest::binary>>, acc) do
    take_until_whitespace(rest, [char | acc])
  end

  defp successful_status(:error), do: :error
  defp successful_status(status), do: status

  defp failed_status(:transaction), do: :error
  defp failed_status(status), do: status

  defp client_version do
    case Application.spec(:quackdb, :vsn) do
      nil -> "quackdb/dev"
      version -> "quackdb/#{version}"
    end
  end

  defp client_platform do
    :system_architecture
    |> :erlang.system_info()
    |> List.to_string()
  end
end

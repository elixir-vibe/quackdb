defmodule QuackDB.DBConnection do
  @moduledoc """
  DBConnection implementation for the remote DuckDB Quack protocol.

  This module owns connection lifecycle, request execution, cursor-based streaming, transaction callbacks, and result normalization. HTTP transport and binary protocol encoding are delegated so the codec remains independent from DBConnection.
  """

  use DBConnection

  alias QuackDB.Error
  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Disconnect
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.AppendRequest
  alias QuackDB.Protocol.Message.FetchRequest
  alias QuackDB.Protocol.Message.FetchResponse
  alias QuackDB.Protocol.Message.PrepareRequest
  alias QuackDB.Protocol.Message.PrepareResponse
  alias QuackDB.Query
  alias QuackDB.Result
  alias QuackDB.Telemetry

  @disconnect_timeout 1_000

  defstruct [
    :uri,
    :token,
    :connection_id,
    :server,
    :transport,
    :transport_owner,
    :transport_options,
    :client_version,
    :telemetry_prefix,
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
          telemetry_prefix: [atom()],
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
    case execute_statement(%Query{statement: "SELECT 1"}, [], [], state) do
      {:ok, _query, _result, state} -> {:ok, state}
      {:error, error, state} -> {:disconnect, error, state}
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
      append_rows(query, table, rows, Keyword.merge(insert_options, options), state)
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
      append_columns(query, table, columns, Keyword.merge(insert_options, options), state)
    else
      {:error,
       Error.new(:unsupported_params, "append queries do not accept params", source: :client),
       state}
    end
  end

  def handle_execute(%Query{} = query, params, options, state) do
    execute_statement(query, params, options, state)
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
    declare_query(query, params, options, state)
  end

  @impl true
  def handle_fetch(_query, %QuackDB.Cursor{} = cursor, options, state) do
    cursor_state = Map.fetch!(state.cursors, cursor.ref)

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
        with {:ok, cursor_state} <- fetch_cursor_state(cursor_state, cursor, options, state) do
          state = put_cursor_state(state, cursor.ref, cursor_state)
          handle_fetch(nil, cursor, options, state)
        else
          {:error, error} -> {:error, annotate_cursor_error(error, cursor), state}
        end
    end
  end

  @impl true
  def handle_deallocate(_query, %QuackDB.Cursor{} = cursor, _options, state) do
    {:ok, cursor_result(cursor, []), %{state | cursors: Map.delete(state.cursors, cursor.ref)}}
  end

  @impl true
  def disconnect(_error, %{connection_id: nil}), do: :ok

  def disconnect(_error, state) do
    request = Codec.encode(%Disconnect{}, connection_id: state.connection_id)
    _ignored = state.transport.(state.uri, request, timeout: @disconnect_timeout)

    if state.transport_owner do
      GenServer.stop(state.transport_owner, :normal, @disconnect_timeout)
    end

    :ok
  end

  defp declare_query(%Query{} = query, params, options, state) do
    with {:ok, statement} <- QuackDB.SQL.format(query.statement, params) do
      do_declare_query(%{query | statement: statement}, options, state)
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp do_declare_query(%Query{} = query, options, state) do
    request =
      %PrepareRequest{sql_query: query.statement}
      |> Codec.encode(connection_id: state.connection_id)

    with {:ok, response} <- state.transport.(state.uri, request, options),
         {:ok, decoded} <- Codec.decode(response),
         {:ok, query, cursor, cursor_state} <- normalize_declare_response(decoded, query, state) do
      state = put_cursor_state(state, cursor.ref, cursor_state)
      {:ok, query, cursor, state}
    else
      {:error, error} ->
        {:error, annotate_error(error, query, state),
         %{state | status: failed_status(state.status)}}
    end
  end

  defp normalize_declare_response({_header, %ErrorResponse{message: message}}, _query, _state) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_declare_response({_header, %PrepareResponse{} = response}, query, state) do
    ref = make_ref()

    query = %{
      query
      | columns: response.result_names,
        result_types: response.result_types,
        result_uuid: response.result_uuid
    }

    cursor = %QuackDB.Cursor{
      ref: ref,
      result_uuid: response.result_uuid,
      columns: response.result_names,
      result_types: response.result_types,
      connection_id: state.connection_id,
      statement: query.statement
    }

    cursor_state = %{
      queued_rows: materialize_rows(response.results, response.result_names),
      done?: not response.needs_more_fetch
    }

    {:ok, query, cursor, cursor_state}
  end

  defp normalize_declare_response({header, _body}, _query, _state) do
    {:error,
     Error.new(:unexpected_message, "expected prepare response, got #{header.type}",
       source: :protocol
     )}
  end

  defp append_rows(%Query{} = query, table, rows, options, state) do
    with {:ok, columns} <- DataChunk.columns_from_rows(rows, options),
         {:ok, batches} <- append_batches(rows, options) do
      options = Keyword.put(options, :columns, columns)
      metadata = append_metadata(query, table, rows, batches, options, state)

      Telemetry.span(state.telemetry_prefix, :append, metadata, fn ->
        result =
          case append_batches(table, batches, options, state) do
            :ok ->
              result = append_result(rows, state)
              {:ok, query, result, %{state | status: successful_status(state.status)}}

            {:error, error} ->
              {:error, annotate_error(error, query, state),
               %{state | status: failed_status(state.status)}}
          end

        {result, append_stop_metadata(result)}
      end)
    else
      {:error, error} ->
        {:error, annotate_error(error, query, state),
         %{state | status: failed_status(state.status)}}
    end
  end

  defp append_batches([], options) do
    case Keyword.get(options, :batch_size, 1) do
      batch_size when is_integer(batch_size) and batch_size >= 1 -> {:ok, [[]]}
      _batch_size -> invalid_batch_size()
    end
  end

  defp append_batches(rows, options) do
    batch_size = Keyword.get(options, :batch_size, length(rows))

    if is_integer(batch_size) and batch_size >= 1 do
      {:ok, Enum.chunk_every(rows, batch_size)}
    else
      invalid_batch_size()
    end
  end

  defp invalid_batch_size do
    {:error,
     Error.new(:invalid_batch_size, "append batch_size must be a positive integer",
       source: :client
     )}
  end

  defp append_columns(%Query{} = query, table, columns, options, state) do
    with {:ok, row_count} <- column_row_count(columns, options),
         {:ok, batches} <- append_column_batches(columns, row_count, options) do
      metadata = append_metadata(query, table, row_count, batches, options, state)

      Telemetry.span(state.telemetry_prefix, :append, metadata, fn ->
        result =
          case append_column_batches(table, batches, options, state) do
            :ok ->
              result = append_result(row_count, state)
              {:ok, query, result, %{state | status: successful_status(state.status)}}

            {:error, error} ->
              {:error, annotate_error(error, query, state),
               %{state | status: failed_status(state.status)}}
          end

        {result, append_stop_metadata(result)}
      end)
    else
      {:error, error} ->
        {:error, annotate_error(error, query, state),
         %{state | status: failed_status(state.status)}}
    end
  end

  defp column_row_count(columns, options) do
    case DataChunk.from_columns(columns, options) do
      {:ok, chunk} -> {:ok, chunk.row_count}
      {:error, _error} = error -> error
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

    if is_integer(batch_size) and batch_size >= 1 do
      {:ok, columns |> Enum.map(&chunk_column(&1, batch_size)) |> transpose_column_batches()}
    else
      invalid_batch_size()
    end
  end

  defp chunk_column({name, values}, batch_size), do: {name, Enum.chunk_every(values, batch_size)}

  defp transpose_column_batches(chunked_columns) do
    chunk_count = chunked_columns |> List.first() |> elem(1) |> length()

    for index <- 0..(chunk_count - 1)//1 do
      Enum.map(chunked_columns, fn {name, chunks} -> {name, Enum.at(chunks, index)} end)
    end
  end

  defp append_batches(table, batches, options, state) do
    Enum.reduce_while(batches, :ok, fn rows, :ok ->
      case append_batch(table, rows, options, state) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp append_column_batches(table, batches, options, state) do
    Enum.reduce_while(batches, :ok, fn columns, :ok ->
      case append_column_batch(table, columns, options, state) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp append_batch(table, rows, options, state) do
    with {:ok, chunk} <- DataChunk.from_rows(rows, options),
         request = %AppendRequest{
           schema_name: Keyword.get(options, :schema, ""),
           table_name: to_string(table),
           append_chunk: chunk
         },
         encoded <- Codec.encode(request, connection_id: state.connection_id),
         {:ok, response} <- state.transport.(state.uri, encoded, options),
         {:ok, decoded} <- Codec.decode(response) do
      normalize_append_response(decoded)
    end
  end

  defp normalize_append_response({_header, %ErrorResponse{message: message}}) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_append_response({_header, %QuackDB.Protocol.Message.SuccessResponse{}}), do: :ok

  defp normalize_append_response({header, _body}) do
    {:error,
     Error.new(:unexpected_message, "expected success response, got #{header.type}",
       source: :protocol
     )}
  end

  defp append_column_batch(table, columns, options, state) do
    with {:ok, chunk} <- DataChunk.from_columns(columns, options),
         request = %AppendRequest{
           schema_name: Keyword.get(options, :schema, ""),
           table_name: to_string(table),
           append_chunk: chunk
         },
         encoded <- Codec.encode(request, connection_id: state.connection_id),
         {:ok, response} <- state.transport.(state.uri, encoded, options),
         {:ok, decoded} <- Codec.decode(response) do
      normalize_append_response(decoded)
    end
  end

  defp append_result(rows, state) when is_list(rows), do: append_result(length(rows), state)

  defp append_result(row_count, state) do
    %Result{
      command: :insert,
      columns: [],
      rows: nil,
      num_rows: row_count,
      connection_id: state.connection_id,
      messages: [],
      metadata: %{}
    }
  end

  defp execute_statement(%Query{} = query, params, options, state) do
    with {:ok, statement} <- QuackDB.SQL.format(query.statement, params) do
      do_execute_statement(%{query | statement: statement}, params, options, state)
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp do_execute_statement(%Query{} = query, params, options, state) do
    Telemetry.span(
      state.telemetry_prefix,
      :query,
      query_metadata(query, params, options, state),
      fn ->
        request =
          %PrepareRequest{sql_query: query.statement}
          |> Codec.encode(connection_id: state.connection_id)

        result =
          with {:ok, response} <- state.transport.(state.uri, request, options),
               {:ok, decoded} <- Codec.decode(response),
               {:ok, query, result} <- normalize_query_response(decoded, query, state, options) do
            {:ok, query, result, %{state | status: successful_status(state.status)}}
          else
            {:error, error} ->
              {:error, annotate_error(error, query, state),
               %{state | status: failed_status(state.status)}}
          end

        {result, result_stop_metadata(result)}
      end
    )
  end

  defp normalize_query_response(
         {_header, %ErrorResponse{message: message}},
         _query,
         _state,
         _options
       ) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_query_response({_header, %PrepareResponse{} = response}, query, state, options) do
    with {:ok, chunks} <- fetch_remaining_chunks(response, state, options) do
      rows = materialize_rows(response.results ++ chunks, response.result_names)

      query = %{
        query
        | columns: response.result_names,
          result_types: response.result_types,
          result_uuid: response.result_uuid
      }

      result =
        %Result{
          command: command(query.statement),
          columns: response.result_names,
          rows: rows,
          num_rows: length(rows),
          connection_id: state.connection_id,
          messages: [],
          metadata: %{
            needs_more_fetch: response.needs_more_fetch,
            result_uuid: response.result_uuid
          }
        }
        |> Result.normalize()

      {:ok, query, result}
    end
  end

  defp normalize_query_response({header, _body}, _query, _state, _options) do
    {:error,
     Error.new(:unexpected_message, "expected prepare response, got #{header.type}",
       source: :protocol
     )}
  end

  defp fetch_remaining_chunks(%PrepareResponse{needs_more_fetch: false}, _state, _options),
    do: {:ok, []}

  defp fetch_remaining_chunks(%PrepareResponse{} = response, state, options) do
    fetch_chunks(response.result_uuid, state, options, [])
  end

  defp fetch_chunks(result_uuid, state, options, chunks) do
    Telemetry.span(
      state.telemetry_prefix,
      :fetch,
      fetch_metadata(result_uuid, options, state),
      fn ->
        request =
          Codec.encode(%FetchRequest{uuid: result_uuid}, connection_id: state.connection_id)

        result =
          with {:ok, response} <- state.transport.(state.uri, request, options),
               {:ok, decoded} <- Codec.decode(response) do
            normalize_fetch_response(decoded, result_uuid, state, options, chunks)
          end

        {result, fetch_stop_metadata(result)}
      end
    )
  end

  defp normalize_fetch_response(
         {_header, %FetchResponse{results: []}},
         _result_uuid,
         _state,
         _options,
         chunks
       ) do
    {:ok, Enum.reverse(chunks)}
  end

  defp normalize_fetch_response(
         {_header, %FetchResponse{} = response},
         result_uuid,
         state,
         options,
         chunks
       ) do
    fetch_chunks(result_uuid, state, options, Enum.reverse(response.results, chunks))
  end

  defp normalize_fetch_response(
         {_header, %ErrorResponse{message: message}},
         _result_uuid,
         _state,
         _options,
         _chunks
       ) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_fetch_response({header, _body}, _result_uuid, _state, _options, _chunks) do
    {:error,
     Error.new(:unexpected_message, "expected fetch response, got #{header.type}",
       source: :protocol
     )}
  end

  defp fetch_cursor_state(cursor_state, cursor, options, state) do
    request =
      Codec.encode(%FetchRequest{uuid: cursor.result_uuid}, connection_id: state.connection_id)

    with {:ok, response} <- state.transport.(state.uri, request, options),
         {:ok, decoded} <- Codec.decode(response) do
      update_cursor_from_fetch(decoded, cursor_state, cursor)
    end
  end

  defp update_cursor_from_fetch({_header, %FetchResponse{results: []}}, cursor_state, _cursor) do
    {:ok, %{cursor_state | done?: true}}
  end

  defp update_cursor_from_fetch({_header, %FetchResponse{} = response}, cursor_state, cursor) do
    rows = materialize_rows(response.results, cursor.columns)
    {:ok, %{cursor_state | queued_rows: cursor_state.queued_rows ++ rows}}
  end

  defp update_cursor_from_fetch(
         {_header, %ErrorResponse{message: message}},
         _cursor_state,
         _cursor
       ) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp update_cursor_from_fetch({header, _body}, _cursor_state, _cursor) do
    {:error,
     Error.new(:unexpected_message, "expected fetch response, got #{header.type}",
       source: :protocol
     )}
  end

  defp put_cursor_state(state, ref, cursor_state) do
    %{state | cursors: Map.put(state.cursors, ref, cursor_state)}
  end

  defp annotate_error(%Error{} = error, %Query{} = query, state) do
    %Error{error | query: query.statement, connection_id: state.connection_id}
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

    with {:ok, uri} <- QuackDB.URI.normalize(uri) do
      {:ok,
       %__MODULE__{
         uri: uri,
         token: Keyword.get(options, :token, ""),
         transport: Keyword.get(options, :transport),
         transport_owner: nil,
         transport_options: transport_options(options),
         client_version: Keyword.get(options, :client_version, client_version()),
         telemetry_prefix: Keyword.get(options, :telemetry_prefix, Telemetry.default_prefix())
       }}
    end
  end

  defp connect_quack(state) do
    with {:ok, state} <- start_transport(state) do
      do_connect_quack(state)
    end
  end

  defp do_connect_quack(state) do
    request =
      %ConnectionRequest{
        auth_string: state.token,
        client_duckdb_version: state.client_version,
        client_platform: client_platform()
      }
      |> Codec.encode()

    with {:ok, response} <- state.transport.(state.uri, request, []),
         {:ok, decoded} <- Codec.decode(response) do
      normalize_connect_response(decoded, state)
    end
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

  defp normalize_connect_response({header, %ConnectionResponse{} = response}, state) do
    {:ok, %{state | connection_id: header.connection_id, server: response}}
  end

  defp normalize_connect_response({_header, %ErrorResponse{message: message}}, _state) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_connect_response({header, _body}, _state) do
    {:error,
     Error.new(:unexpected_message, "expected connection response, got #{header.type}",
       source: :protocol
     )}
  end

  defp take_cursor_rows(cursor, max_rows) do
    {rows, remaining} = Enum.split(cursor.queued_rows, max_rows)
    {rows, %{cursor | queued_rows: remaining}}
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

  defp fetch_metadata(result_uuid, options, state) do
    options
    |> metadata_from_options(state)
    |> Map.put(:result_uuid, result_uuid)
  end

  defp metadata_from_options(options, state) do
    %{
      connection_id: state.connection_id,
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

  defp append_stop_metadata(result), do: result_stop_metadata(result)

  defp fetch_stop_metadata({:ok, chunks}) do
    %{chunks: length(chunks), result: :ok}
  end

  defp fetch_stop_metadata({:error, %Error{} = error}) do
    %{error: error, result: :error}
  end

  defp command(statement) do
    statement
    |> IO.iodata_to_binary()
    |> first_sql_word()
    |> case do
      "" -> :unknown
      word -> word |> String.downcase() |> String.to_atom()
    end
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

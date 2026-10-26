defmodule QuackDB.Protocol.Codec do
  @moduledoc """
  Encoder and decoder for top-level Quack protocol messages.

  QuackDB speaks Quack protocol version 3, the version DuckDB 2.0 serves. Every
  message is a header object followed by a body object. Fetch responses and
  send-data requests continue with a raw blob of `DataChunk` objects whose
  count the body declares.
  """

  alias QuackDB.Error
  alias QuackDB.Protocol
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message
  alias QuackDB.Protocol.Reader

  import QuackDB.Protocol.Writer,
    only: [
      bool: 1,
      end_object: 0,
      field: 2,
      hugeint: 1,
      list: 2,
      nullable: 2,
      optional_index: 1,
      string: 1,
      uleb128: 1
    ]

  alias Message.Acknowledgement
  alias Message.CancelRequest
  alias Message.ConnectionRequest
  alias Message.ConnectionResponse
  alias Message.Disconnect
  alias Message.ErrorResponse
  alias Message.FetchRequest
  alias Message.FetchResponse
  alias Message.Header
  alias Message.HeartbeatRequest
  alias Message.PrepareRequest
  alias Message.PrepareResponse
  alias Message.SendDataRequest
  alias Message.SendDataResponse
  alias Message.SuccessResponse

  @field_end Protocol.field_end()

  @type decoded_message :: {Header.t(), struct()}

  @message_modules %{
    connection_request: ConnectionRequest,
    connection_response: ConnectionResponse,
    prepare_request: PrepareRequest,
    prepare_response: PrepareResponse,
    fetch_request: FetchRequest,
    fetch_response: FetchResponse,
    send_data_request: SendDataRequest,
    send_data_response: SendDataResponse,
    success_response: SuccessResponse,
    disconnect_message: Disconnect,
    cancel_request: CancelRequest,
    acknowledgement: Acknowledgement,
    heartbeat_request: HeartbeatRequest,
    error_response: ErrorResponse
  }

  @message_types Map.new(@message_modules, fn {type, module} -> {module, type} end)

  @spec encode(struct(), Keyword.t()) :: iodata()
  def encode(message, options \\ []) do
    header = %Header{
      type: message_type(message),
      connection_id: Keyword.get(options, :connection_id, ""),
      client_query_id: Keyword.get(options, :client_query_id)
    }

    [encode_header(header), encode_body(message), encode_blob(message)]
  end

  @spec decode(binary()) :: {:ok, decoded_message()} | {:error, Error.t()}
  def decode(binary) do
    with {:ok, header, rest} <- decode_header(binary),
         {:ok, body, rest} <- decode_body(header.type, rest),
         {:ok, body, rest} <- decode_blob(body, rest),
         :ok <- expect_empty(rest) do
      {:ok, {header, body}}
    end
  end

  # Decoded values never hold binaries in these structs, so copying skips them.
  @binary_free_structs [
    Date,
    Time,
    NaiveDateTime,
    DateTime,
    Decimal,
    QuackDB.Interval,
    QuackDB.NanosecondTime,
    QuackDB.NanosecondTimestamp,
    QuackDB.TimeWithTimeZone
  ]

  @doc """
  Copies every binary in a decoded prepare or fetch response off the
  response binary.

  Decoded strings, blobs, column names, and type metadata of 64 bytes or more
  are sub-binaries of the response they came from, so keeping any of them
  keeps the whole response in memory. Copies are independent of it; shorter
  binaries already are. Other messages are returned unchanged.
  """
  @spec copy_binaries(struct()) :: struct()
  def copy_binaries(%PrepareResponse{} = response) do
    %{
      response
      | result_names: copy(response.result_names),
        result_types: copy(response.result_types),
        results: copy(response.results)
    }
  end

  def copy_binaries(%FetchResponse{} = response),
    do: %{response | results: copy(response.results)}

  def copy_binaries(message), do: message

  defp copy(%DataChunk{} = chunk),
    do: %{chunk | types: copy(chunk.types), columns: Enum.map(chunk.columns, &copy_vector/1)}

  # Binaries under 64 bytes are already copied out when they are matched, so
  # only those that still point into a larger binary need a copy.
  defp copy(binary) when is_binary(binary) do
    if :binary.referenced_byte_size(binary) > byte_size(binary),
      do: :binary.copy(binary),
      else: binary
  end

  defp copy(list) when is_list(list), do: Enum.map(list, &copy/1)
  defp copy(%module{} = struct) when module in @binary_free_structs, do: struct

  defp copy(%module{} = struct),
    do: struct |> Map.from_struct() |> copy() |> then(&struct(module, &1))

  defp copy(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {copy(key), copy(value)} end)

  defp copy(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> copy() |> List.to_tuple()
  defp copy(term), do: term

  # Only columns whose values can hold binaries are walked.
  defp copy_vector(vector) do
    values =
      if LogicalType.holds_binaries?(vector.type), do: copy(vector.values), else: vector.values

    %{vector | type: copy(vector.type), values: values}
  end

  @spec encode_header(Header.t()) :: iodata()
  def encode_header(%Header{} = header) do
    [
      field(1, uleb128(Protocol.message_type(header.type))),
      encode_string(2, header.connection_id),
      field(3, optional_index(header.client_query_id)),
      end_object()
    ]
  end

  @spec decode_header(binary()) :: Reader.read_result(Header.t())
  def decode_header(binary) do
    decode_fields(binary, %Header{}, :header, %{
      1 => {:type, &read_message_type/1},
      2 => {:connection_id, &Reader.read_string/1},
      3 => {:client_query_id, &Reader.read_optional_index/1}
    })
  end

  defp encode_body(%ConnectionRequest{} = message) do
    [
      encode_string(1, message.auth_string),
      encode_string(2, message.client_duckdb_version),
      encode_string(3, message.client_platform),
      encode_index(4, message.min_supported_quack_version),
      encode_index(5, message.max_supported_quack_version),
      encode_string(6, message.client_id),
      encode_index(7, message.heartbeat_timeout_seconds),
      end_object()
    ]
  end

  defp encode_body(%ConnectionResponse{} = message) do
    [
      encode_string(1, message.server_duckdb_version),
      encode_string(2, message.server_platform),
      encode_index(3, message.quack_version),
      encode_index(4, message.heartbeat_timeout_seconds),
      end_object()
    ]
  end

  defp encode_body(%PrepareRequest{} = message) do
    [
      encode_string(1, message.sql_query),
      field(2, hugeint(message.query_uuid)),
      encode_optional_index(3, message.inline_rows),
      end_object()
    ]
  end

  defp encode_body(%PrepareResponse{} = message) do
    [
      encode_list(1, message.result_types, &LogicalType.encode/1),
      encode_list(2, message.result_names, &string/1),
      encode_flag(3, message.needs_more_fetch),
      encode_list(
        4,
        message.results,
        &nullable(&1, fn chunk -> DataChunk.encode_wrapper(chunk) end)
      ),
      field(5, hugeint(message.query_uuid)),
      end_object()
    ]
  end

  defp encode_body(%FetchRequest{} = message) do
    [
      field(1, hugeint(message.query_uuid)),
      encode_index(2, message.batch_index),
      encode_index(3, message.ack_index),
      end_object()
    ]
  end

  defp encode_body(%FetchResponse{} = message) do
    [
      encode_index(1, length(message.results)),
      encode_optional_index(2, message.total_batches),
      encode_optional_index(3, message.batch_index),
      end_object()
    ]
  end

  defp encode_body(%SendDataRequest{} = message) do
    [
      encode_string(1, message.stream_id),
      encode_index(2, length(message.chunks)),
      encode_optional_index(3, message.total_batches),
      encode_optional_index(4, message.batch_index),
      end_object()
    ]
  end

  defp encode_body(%SendDataResponse{} = message) do
    [field(1, optional_index(message.accept_budget)), end_object()]
  end

  defp encode_body(%CancelRequest{} = message) do
    [field(1, hugeint(message.query_uuid)), end_object()]
  end

  defp encode_body(%Acknowledgement{query_uuid: 0}), do: end_object()

  defp encode_body(%Acknowledgement{} = message) do
    [field(1, hugeint(message.query_uuid)), end_object()]
  end

  defp encode_body(%ErrorResponse{} = message) do
    [
      encode_string(1, message.message),
      encode_string(2, message.exception_type),
      encode_string_map(3, message.extra_info),
      encode_flag(4, message.must_invalidate),
      end_object()
    ]
  end

  defp encode_body(%module{}) when module in [Disconnect, SuccessResponse, HeartbeatRequest] do
    end_object()
  end

  defp encode_blob(%FetchResponse{results: chunks}), do: Enum.map(chunks, &DataChunk.encode/1)
  defp encode_blob(%SendDataRequest{chunks: chunks}), do: Enum.map(chunks, &DataChunk.encode/1)
  defp encode_blob(_message), do: []

  defp decode_body(:connection_request, binary) do
    decode_fields(binary, %ConnectionRequest{}, :connection_request, %{
      1 => {:auth_string, &Reader.read_string/1},
      2 => {:client_duckdb_version, &Reader.read_string/1},
      3 => {:client_platform, &Reader.read_string/1},
      4 => {:min_supported_quack_version, &Reader.read_uleb128/1},
      5 => {:max_supported_quack_version, &Reader.read_uleb128/1},
      6 => {:client_id, &Reader.read_string/1},
      7 => {:heartbeat_timeout_seconds, &Reader.read_uleb128/1}
    })
  end

  defp decode_body(:connection_response, binary) do
    decode_fields(binary, %ConnectionResponse{}, :connection_response, %{
      1 => {:server_duckdb_version, &Reader.read_string/1},
      2 => {:server_platform, &Reader.read_string/1},
      3 => {:quack_version, &Reader.read_uleb128/1},
      4 => {:heartbeat_timeout_seconds, &Reader.read_uleb128/1}
    })
  end

  defp decode_body(:prepare_request, binary) do
    decode_fields(binary, %PrepareRequest{}, :prepare_request, %{
      1 => {:sql_query, &Reader.read_string/1},
      2 => {:query_uuid, &Reader.read_hugeint/1},
      3 => {:inline_rows, &Reader.read_optional_index/1}
    })
  end

  defp decode_body(:prepare_response, binary) do
    decode_fields(binary, %PrepareResponse{}, :prepare_response, %{
      1 => {:result_types, &Reader.read_list(&1, fn rest -> LogicalType.decode(rest) end)},
      2 => {:result_names, &Reader.read_list(&1, fn rest -> Reader.read_string(rest) end)},
      3 => {:needs_more_fetch, &Reader.read_bool/1},
      4 => {:results, &read_chunk_pointer_list/1},
      5 => {:query_uuid, &Reader.read_hugeint/1}
    })
  end

  defp decode_body(:fetch_request, binary) do
    decode_fields(binary, %FetchRequest{}, :fetch_request, %{
      1 => {:query_uuid, &Reader.read_hugeint/1},
      2 => {:batch_index, &Reader.read_uleb128/1},
      3 => {:ack_index, &Reader.read_uleb128/1}
    })
  end

  defp decode_body(:fetch_response, binary) do
    decode_fields(binary, %FetchResponse{results: 0}, :fetch_response, %{
      1 => {:results, &Reader.read_uleb128/1},
      2 => {:total_batches, &Reader.read_optional_index/1},
      3 => {:batch_index, &Reader.read_optional_index/1}
    })
  end

  defp decode_body(:send_data_request, binary) do
    decode_fields(binary, %SendDataRequest{chunks: 0}, :send_data_request, %{
      1 => {:stream_id, &Reader.read_string/1},
      2 => {:chunks, &Reader.read_uleb128/1},
      3 => {:total_batches, &Reader.read_optional_index/1},
      4 => {:batch_index, &Reader.read_optional_index/1}
    })
  end

  defp decode_body(:send_data_response, binary) do
    decode_fields(binary, %SendDataResponse{}, :send_data_response, %{
      1 => {:accept_budget, &Reader.read_optional_index/1}
    })
  end

  defp decode_body(:cancel_request, binary) do
    decode_fields(binary, %CancelRequest{}, :cancel_request, %{
      1 => {:query_uuid, &Reader.read_hugeint/1}
    })
  end

  defp decode_body(:acknowledgement, binary) do
    decode_fields(binary, %Acknowledgement{}, :acknowledgement, %{
      1 => {:query_uuid, &Reader.read_hugeint/1}
    })
  end

  defp decode_body(:error_response, binary) do
    decode_fields(binary, %ErrorResponse{}, :error_response, %{
      1 => {:message, &Reader.read_string/1},
      2 => {:exception_type, &Reader.read_string/1},
      3 => {:extra_info, &read_string_map/1},
      4 => {:must_invalidate, &Reader.read_bool/1}
    })
  end

  defp decode_body(type, binary) when is_map_key(@message_modules, type) do
    decode_empty_body(binary, struct(Map.fetch!(@message_modules, type)))
  end

  defp decode_body(type, _binary) do
    error(:unsupported_message_type, "decoding #{type} messages is not supported")
  end

  defp decode_blob(%FetchResponse{results: count} = response, binary) do
    with {:ok, chunks, rest} <- read_chunk_blob(binary, count) do
      {:ok, %{response | results: chunks}, rest}
    end
  end

  defp decode_blob(%SendDataRequest{chunks: count} = request, binary) do
    with {:ok, chunks, rest} <- read_chunk_blob(binary, count) do
      {:ok, %{request | chunks: chunks}, rest}
    end
  end

  defp decode_blob(message, rest), do: {:ok, message, rest}

  defp read_chunk_blob(binary, count), do: read_chunk_blob(binary, count, [])

  defp read_chunk_blob(rest, 0, chunks), do: {:ok, Enum.reverse(chunks), rest}

  defp read_chunk_blob(binary, remaining, chunks) do
    with {:ok, chunk, rest} <- DataChunk.decode(binary) do
      read_chunk_blob(rest, remaining - 1, [chunk | chunks])
    end
  end

  # Decodes an object whose fields are listed in `fields` as
  # `%{field_id => {struct_key, reader}}`. Absent fields keep the struct
  # default, matching DuckDB's `WritePropertyWithDefault`.
  defp decode_fields(binary, acc, name, fields) do
    read_field = fn field_id, rest, acc ->
      case fields do
        %{^field_id => {key, read}} ->
          with {:ok, value, rest} <- read.(rest), do: {:ok, Map.put(acc, key, value), rest}

        _fields ->
          :unknown
      end
    end

    Reader.read_object(binary, acc, read_field, {:"unknown_#{name}_field", humanize(name)})
  end

  defp humanize(:header), do: "message header"
  defp humanize(name), do: name |> Atom.to_string() |> String.replace("_", " ")

  defp decode_empty_body(binary, message) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      if field_id == @field_end do
        {:ok, message, rest}
      else
        error(:unexpected_body_field, "expected an empty message body")
      end
    end
  end

  defp read_message_type(binary) do
    with {:ok, type_id, rest} <- Reader.read_uleb128(binary),
         {:ok, type} <- type_name(type_id) do
      {:ok, type, rest}
    end
  end

  defp read_chunk_pointer_list(binary) do
    with {:ok, chunks, rest} <-
           Reader.read_list(binary, fn rest ->
             Reader.read_nullable(rest, &DataChunk.decode_wrapper/1)
           end) do
      if Enum.any?(chunks, &is_nil/1) do
        error(:null_data_chunk, "encountered null DataChunk pointer in result list")
      else
        {:ok, chunks, rest}
      end
    end
  end

  defp read_string_map(binary) do
    with {:ok, entries, rest} <- Reader.read_list(binary, &read_string_map_entry/1) do
      {:ok, Map.new(entries), rest}
    end
  end

  defp read_string_map_entry(binary) do
    with {:ok, entry, rest} <-
           decode_fields(binary, %{key: "", value: ""}, :map_entry, %{
             0 => {:key, &Reader.read_string/1},
             1 => {:value, &Reader.read_string/1}
           }) do
      {:ok, {entry.key, entry.value}, rest}
    end
  end

  defp encode_string(_field_id, value) when value in ["", nil], do: []
  defp encode_string(field_id, value), do: field(field_id, string(value))

  defp encode_index(_field_id, value) when value in [0, nil], do: []
  defp encode_index(field_id, value), do: field(field_id, uleb128(value))

  defp encode_optional_index(_field_id, nil), do: []
  defp encode_optional_index(field_id, value), do: field(field_id, optional_index(value))

  defp encode_list(_field_id, [], _write), do: []
  defp encode_list(field_id, values, write), do: field(field_id, list(values, write))

  defp encode_flag(_field_id, false), do: []
  defp encode_flag(field_id, true), do: field(field_id, bool(true))

  defp encode_string_map(_field_id, map) when map_size(map) == 0, do: []

  defp encode_string_map(field_id, map) do
    field(
      field_id,
      list(Enum.sort(map), fn {key, value} ->
        [encode_string(0, key), encode_string(1, value), end_object()]
      end)
    )
  end

  defp message_type(%module{}), do: Map.fetch!(@message_types, module)

  defp type_name(type_id) do
    Protocol.message_types()
    |> Enum.find_value(fn {name, id} -> if id == type_id, do: name end)
    |> case do
      nil -> error(:unknown_message_type, "unknown Quack message type #{type_id}")
      name -> {:ok, name}
    end
  end

  defp expect_empty(<<>>), do: :ok

  defp expect_empty(_rest) do
    error(:trailing_bytes, "message has trailing bytes after the body")
  end

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

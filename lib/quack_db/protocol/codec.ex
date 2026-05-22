defmodule QuackDB.Protocol.Codec do
  @moduledoc """
  Encoder and decoder for top-level Quack protocol messages.

  This module converts between message structs and wire-format binaries. It is
  kept independent from HTTP, DBConnection, and public client APIs so protocol
  compatibility can be tested in isolation.
  """

  alias QuackDB.Error
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Writer

  alias Message.AppendRequest
  alias Message.ConnectionRequest
  alias Message.ConnectionResponse
  alias Message.Disconnect
  alias Message.ErrorResponse
  alias Message.FetchRequest
  alias Message.Header
  alias Message.PrepareRequest
  alias Message.PrepareResponse
  alias Message.FetchResponse
  alias Message.SuccessResponse

  @type decoded_message :: {Header.t(), struct()}

  @spec encode(struct(), Keyword.t()) :: iodata()
  def encode(message, options \\ []) do
    header = %Header{
      type: message_type(message),
      connection_id: Keyword.get(options, :connection_id, ""),
      client_query_id: Keyword.get(options, :client_query_id)
    }

    [encode_header(header), encode_body(message)]
  end

  @spec decode(binary()) :: {:ok, decoded_message()} | {:error, Error.t()}
  def decode(binary) do
    with {:ok, header, rest} <- decode_header(binary),
         {:ok, body, rest} <- decode_body(header.type, rest),
         :ok <- expect_empty(rest) do
      {:ok, {header, body}}
    end
  end

  @spec encode_header(Header.t()) :: iodata()
  def encode_header(%Header{} = header) do
    [
      Writer.field(1, Writer.uleb128(QuackDB.Protocol.message_type(header.type))),
      encode_connection_id_header_field(header.connection_id),
      Writer.field(3, Writer.optional_index(header.client_query_id)),
      Writer.end_object()
    ]
  end

  @spec decode_header(binary()) :: Reader.read_result(Header.t())
  def decode_header(binary), do: decode_header(binary, %Header{})

  defp encode_body(%ConnectionRequest{} = message) do
    [
      Writer.field(1, Writer.string(message.auth_string)),
      Writer.field(2, Writer.string(message.client_duckdb_version)),
      Writer.field(3, Writer.string(message.client_platform)),
      Writer.field(4, Writer.uleb128(message.min_supported_quack_version)),
      Writer.field(5, Writer.uleb128(message.max_supported_quack_version)),
      Writer.end_object()
    ]
  end

  defp encode_body(%PrepareRequest{} = message) do
    [Writer.field(1, Writer.string(message.sql_query)), Writer.end_object()]
  end

  defp encode_body(%FetchRequest{} = message) do
    [Writer.field(1, Writer.hugeint(message.uuid)), Writer.end_object()]
  end

  defp encode_body(%Disconnect{}) do
    Writer.end_object()
  end

  defp encode_body(%SuccessResponse{}) do
    Writer.end_object()
  end

  defp encode_body(%ErrorResponse{} = message) do
    [Writer.field(1, Writer.string(message.message)), Writer.end_object()]
  end

  defp encode_body(%AppendRequest{}) do
    raise ArgumentError, "append request encoding needs DataChunk support first"
  end

  defp decode_body(:connection_request, binary) do
    decode_connection_request(binary, %ConnectionRequest{})
  end

  defp decode_body(:connection_response, binary) do
    decode_connection_response(binary, %ConnectionResponse{})
  end

  defp decode_body(:prepare_request, binary) do
    decode_prepare_request(binary, %PrepareRequest{})
  end

  defp decode_body(:fetch_request, binary) do
    decode_fetch_request(binary, %FetchRequest{})
  end

  defp decode_body(:prepare_response, binary) do
    decode_prepare_response(binary, %PrepareResponse{})
  end

  defp decode_body(:fetch_response, binary) do
    decode_fetch_response(binary, %FetchResponse{})
  end

  defp decode_body(:success_response, binary) do
    decode_empty_body(binary, %SuccessResponse{})
  end

  defp decode_body(:disconnect_message, binary) do
    decode_empty_body(binary, %Disconnect{})
  end

  defp decode_body(:error_response, binary) do
    decode_error_response(binary, %ErrorResponse{})
  end

  defp decode_body(type, _binary) do
    error(:unsupported_message_type, "decoding #{type} messages is not implemented yet")
  end

  defp decode_header(binary, header) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, header, rest}

        field_id == 1 ->
          with {:ok, type_id, rest} <- Reader.read_uleb128(rest),
               {:ok, type} <- type_name(type_id) do
            decode_header(rest, %{header | type: type})
          end

        field_id == 2 ->
          with {:ok, connection_id, rest} <- Reader.read_string(rest) do
            decode_header(rest, %{header | connection_id: connection_id})
          end

        field_id == 3 ->
          with {:ok, client_query_id, rest} <- Reader.read_optional_index(rest) do
            decode_header(rest, %{header | client_query_id: client_query_id})
          end

        true ->
          error(:unknown_header_field, "unknown message header field #{field_id}")
      end
    end
  end

  defp decode_connection_request(binary, request) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, request, rest}

        field_id == 1 ->
          with {:ok, auth_string, rest} <- Reader.read_string(rest) do
            decode_connection_request(rest, %{request | auth_string: auth_string})
          end

        field_id == 2 ->
          with {:ok, version, rest} <- Reader.read_string(rest) do
            decode_connection_request(rest, %{request | client_duckdb_version: version})
          end

        field_id == 3 ->
          with {:ok, platform, rest} <- Reader.read_string(rest) do
            decode_connection_request(rest, %{request | client_platform: platform})
          end

        field_id == 4 ->
          with {:ok, version, rest} <- Reader.read_uleb128(rest) do
            decode_connection_request(rest, %{request | min_supported_quack_version: version})
          end

        field_id == 5 ->
          with {:ok, version, rest} <- Reader.read_uleb128(rest) do
            decode_connection_request(rest, %{request | max_supported_quack_version: version})
          end

        true ->
          error(:unknown_connection_request_field, "unknown connection request field #{field_id}")
      end
    end
  end

  defp decode_connection_response(binary, response) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, response, rest}

        field_id == 1 ->
          with {:ok, version, rest} <- Reader.read_string(rest) do
            decode_connection_response(rest, %{response | server_duckdb_version: version})
          end

        field_id == 2 ->
          with {:ok, platform, rest} <- Reader.read_string(rest) do
            decode_connection_response(rest, %{response | server_platform: platform})
          end

        field_id == 3 ->
          with {:ok, version, rest} <- Reader.read_uleb128(rest) do
            decode_connection_response(rest, %{response | quack_version: version})
          end

        true ->
          error(
            :unknown_connection_response_field,
            "unknown connection response field #{field_id}"
          )
      end
    end
  end

  defp decode_prepare_request(binary, request) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, request, rest}

        field_id == 1 ->
          with {:ok, sql_query, rest} <- Reader.read_string(rest) do
            decode_prepare_request(rest, %{request | sql_query: sql_query})
          end

        true ->
          error(:unknown_prepare_request_field, "unknown prepare request field #{field_id}")
      end
    end
  end

  defp decode_fetch_request(binary, request) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, request, rest}

        field_id == 1 ->
          with {:ok, uuid, rest} <- Reader.read_hugeint(rest) do
            decode_fetch_request(rest, %{request | uuid: uuid})
          end

        true ->
          error(:unknown_fetch_request_field, "unknown fetch request field #{field_id}")
      end
    end
  end

  defp decode_prepare_response(binary, response) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, response, rest}

        field_id == 1 ->
          with {:ok, result_types, rest} <- Reader.read_list(rest, &LogicalType.decode/1) do
            decode_prepare_response(rest, %{response | result_types: result_types})
          end

        field_id == 2 ->
          with {:ok, result_names, rest} <- Reader.read_list(rest, &Reader.read_string/1) do
            decode_prepare_response(rest, %{response | result_names: result_names})
          end

        field_id == 3 ->
          with {:ok, needs_more_fetch, rest} <- Reader.read_bool(rest) do
            decode_prepare_response(rest, %{response | needs_more_fetch: needs_more_fetch})
          end

        field_id == 4 ->
          with {:ok, results, rest} <- read_chunk_pointer_list(rest) do
            decode_prepare_response(rest, %{response | results: results})
          end

        field_id == 5 ->
          with {:ok, result_uuid, rest} <- Reader.read_hugeint(rest) do
            decode_prepare_response(rest, %{response | result_uuid: result_uuid})
          end

        true ->
          error(:unknown_prepare_response_field, "unknown prepare response field #{field_id}")
      end
    end
  end

  defp decode_fetch_response(binary, response) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, response, rest}

        field_id == 1 ->
          with {:ok, results, rest} <- read_chunk_pointer_list(rest) do
            decode_fetch_response(rest, %{response | results: results})
          end

        field_id == 2 ->
          with {:ok, batch_index, rest} <- Reader.read_optional_index(rest) do
            decode_fetch_response(rest, %{response | batch_index: batch_index})
          end

        true ->
          error(:unknown_fetch_response_field, "unknown fetch response field #{field_id}")
      end
    end
  end

  defp decode_error_response(binary, response) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, response, rest}

        field_id == 1 ->
          with {:ok, message, rest} <- Reader.read_string(rest) do
            decode_error_response(rest, %{response | message: message})
          end

        true ->
          error(:unknown_error_response_field, "unknown error response field #{field_id}")
      end
    end
  end

  defp decode_empty_body(binary, message) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      if field_id == QuackDB.Protocol.field_end() do
        {:ok, message, rest}
      else
        error(:unexpected_body_field, "expected an empty message body")
      end
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

  defp encode_connection_id_header_field(""), do: []
  defp encode_connection_id_header_field(nil), do: []
  defp encode_connection_id_header_field(value), do: Writer.field(2, Writer.string(value))

  defp message_type(%ConnectionRequest{}), do: :connection_request
  defp message_type(%PrepareRequest{}), do: :prepare_request
  defp message_type(%FetchRequest{}), do: :fetch_request
  defp message_type(%AppendRequest{}), do: :append_request
  defp message_type(%SuccessResponse{}), do: :success_response
  defp message_type(%Disconnect{}), do: :disconnect_message
  defp message_type(%ErrorResponse{}), do: :error_response

  defp type_name(type_id) do
    QuackDB.Protocol.message_types()
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

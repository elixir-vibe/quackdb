defmodule QuackDB.Protocol.CodecTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.FetchRequest
  alias QuackDB.Protocol.Message.PrepareRequest
  alias QuackDB.Protocol.Writer

  test "encodes connection request messages" do
    message = %ConnectionRequest{
      auth_string: "token",
      client_duckdb_version: "1.5.0",
      client_platform: "elixir",
      min_supported_quack_version: 1,
      max_supported_quack_version: 1
    }

    binary = IO.iodata_to_binary(Codec.encode(message))

    assert {:ok, {%Header{type: :connection_request, client_query_id: nil}, ^message}} =
             Codec.decode(binary)

    assert binary =~ <<3::little-16>>
  end

  test "decodes connection request messages" do
    message = %ConnectionRequest{auth_string: "token", client_duckdb_version: "quackdb/dev"}
    binary = IO.iodata_to_binary(Codec.encode(message))

    assert {:ok, {%Header{type: :connection_request}, %ConnectionRequest{} = decoded}} =
             Codec.decode(binary)

    assert decoded.auth_string == "token"
    assert decoded.client_duckdb_version == "quackdb/dev"
    assert decoded.min_supported_quack_version == 1
    assert decoded.max_supported_quack_version == 1
  end

  test "encodes prepare request messages with connection ids" do
    message = %PrepareRequest{sql_query: "SELECT 1"}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok,
            {%Header{type: :prepare_request, connection_id: "conn-1", client_query_id: nil},
             ^message}} = Codec.decode(binary)
  end

  test "decodes prepare request messages" do
    message = %PrepareRequest{sql_query: "SELECT 1"}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok,
            {%Header{type: :prepare_request, connection_id: "conn-1"},
             %PrepareRequest{sql_query: "SELECT 1"}}} = Codec.decode(binary)
  end

  test "decodes fetch request messages" do
    message = %FetchRequest{uuid: 123_456_789_012_345_678_901_234_567_890}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok,
            {%Header{type: :fetch_request, connection_id: "conn-1"},
             %FetchRequest{uuid: 123_456_789_012_345_678_901_234_567_890}}} = Codec.decode(binary)
  end

  test "decodes connection response messages" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
        <<1::little-16, 5, "1.5.0">>,
        <<2::little-16, 6, "darwin">>,
        <<3::little-16, 1>>,
        <<0xFFFF::little-16>>
      ])

    assert {:ok,
            {%Header{type: :connection_response, connection_id: "conn-1"},
             %ConnectionResponse{
               server_duckdb_version: "1.5.0",
               server_platform: "darwin",
               quack_version: 1
             }}} = Codec.decode(binary)
  end

  test "reports unknown message types" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :invalid}),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unsupported_message_type, message: message}} =
             Codec.decode(binary)

    assert message == "decoding invalid messages is not implemented yet"
  end

  test "reports unknown message type ids" do
    binary =
      IO.iodata_to_binary([
        Writer.field(1, Writer.uleb128(999_999)),
        Writer.end_object(),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_message_type, message: message}} =
             Codec.decode(binary)

    assert message == "unknown Quack message type 999999"
  end

  test "reports unknown header fields" do
    binary =
      IO.iodata_to_binary([
        Writer.field(999, Writer.uleb128(1)),
        Writer.end_object(),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_header_field, message: message}} =
             Codec.decode(binary)

    assert message == "unknown message header field 999"
  end

  test "reports unexpected fields in empty message bodies" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :success_response}),
        Writer.field(1, Writer.string("unexpected")),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unexpected_body_field, message: message}} =
             Codec.decode(binary)

    assert message == "expected an empty message body"
  end

  test "reports trailing bytes after message bodies" do
    binary =
      IO.iodata_to_binary([
        Codec.encode(%ErrorResponse{message: "bad"}),
        <<0>>
      ])

    assert {:error, %QuackDB.Error{code: :trailing_bytes, message: message}} =
             Codec.decode(binary)

    assert message == "message has trailing bytes after the body"
  end

  test "reports missing append chunks" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :append_request, connection_id: "conn-1"}),
        Writer.field(2, Writer.string("events")),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :missing_append_chunk, message: message}} =
             Codec.decode(binary)

    assert message == "APPEND_REQUEST is missing append chunk"
  end

  test "decodes error response messages" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :error_response, connection_id: "conn-1"}),
        <<1::little-16, 13, "Invalid token">>,
        <<0xFFFF::little-16>>
      ])

    assert {:ok, {%Header{type: :error_response}, %ErrorResponse{message: "Invalid token"}}} =
             Codec.decode(binary)
  end
end

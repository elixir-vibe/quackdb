defmodule QuackDB.Protocol.CodecTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.FetchRequest
  alias QuackDB.Protocol.Message.PrepareRequest

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

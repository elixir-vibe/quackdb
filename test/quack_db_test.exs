defmodule QuackDBTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.Header

  test "exposes protocol message type ids" do
    assert QuackDB.Protocol.message_type(:connection_request) == 1
    assert QuackDB.Protocol.message_type(:error_response) == 100
  end

  test "queries through DBConnection" do
    transport = fn _uri, request, _options ->
      if match?(
           {:ok, {%Header{type: :connection_request}, _body}},
           Codec.decode(IO.iodata_to_binary(request))
         ) do
        response = [
          Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
          <<1::little-16, 5, "1.5.0">>,
          <<2::little-16, 6, "darwin">>,
          <<3::little-16, 1>>,
          <<0xFFFF::little-16>>
        ]

        {:ok, IO.iodata_to_binary(response)}
      else
        chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
        {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk])}
      end
    end

    connection = start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport})

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
  end
end

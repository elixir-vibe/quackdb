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

  test "queries column-oriented results" do
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
        chunk =
          QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
            {:integer, :int32, [1, 2]},
            {:varchar, :varchar, ["duck", "goose"]}
          ])

        {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk], names: ["id", "name"])}
      end
    end

    connection = start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport})

    assert {:ok, %{"id" => [1, 2], "name" => ["duck", "goose"]}} =
             QuackDB.columns(connection, "SELECT id, name FROM events")

    assert {:ok, %QuackDB.Columns{names: ["id", "name"], num_rows: 2} = columns} =
             QuackDB.columnar(connection, "SELECT id, name FROM events")

    assert columns["name"] == ["duck", "goose"]
  end

  test "streams column-oriented batches" do
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
        chunk =
          QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
            {:integer, :int32, [1, 2]},
            {:varchar, :varchar, ["duck", "goose"]}
          ])

        {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk], names: ["id", "name"])}
      end
    end

    connection = start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport})

    assert {:ok, [%{"id" => [1, 2], "name" => ["duck", "goose"]}]} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.column_batches("SELECT id, name FROM events")
               |> Enum.to_list()
             end)

    assert {:ok, [%QuackDB.Columns{names: ["id", "name"], num_rows: 2} = columns]} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.columnar_batches("SELECT id, name FROM events")
               |> Enum.to_list()
             end)

    assert columns["id"] == [1, 2]
  end
end

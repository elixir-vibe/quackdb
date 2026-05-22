defmodule QuackDB.ConnectionTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Header

  test "performs a connection handshake on start" do
    transport = fn _uri, _request, _options ->
      response = [
        Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
        <<1::little-16, 5, "1.5.0">>,
        <<2::little-16, 6, "darwin">>,
        <<3::little-16, 1>>,
        <<0xFFFF::little-16>>
      ]

      {:ok, IO.iodata_to_binary(response)}
    end

    connection =
      start_supervised!({QuackDB.Connection, uri: "quack://localhost:9494", transport: transport})

    assert %QuackDB.Connection{
             connection_id: "conn-1",
             server: %ConnectionResponse{server_duckdb_version: "1.5.0", quack_version: 1}
           } = :sys.get_state(connection)
  end

  test "returns server errors from query responses" do
    parent = self()

    transport = fn _uri, request, _options ->
      send(parent, {:request, IO.iodata_to_binary(request)})

      response = [
        Codec.encode_header(%Header{type: :error_response, connection_id: "conn-1"}),
        <<1::little-16, 12, "syntax error">>,
        <<0xFFFF::little-16>>
      ]

      {:ok, IO.iodata_to_binary(response)}
    end

    connection =
      start_supervised!(
        {QuackDB.Connection, uri: "http://localhost:9494", connect: false, transport: transport}
      )

    :sys.replace_state(connection, &%{&1 | connection_id: "conn-1"})

    assert {:error, %QuackDB.Error{code: :server_error, message: "syntax error"}} =
             QuackDB.query(connection, "SELECT")

    assert_received {:request, request}

    assert {:ok, {%Header{type: :prepare_request, connection_id: "conn-1"}, _body}} =
             Codec.decode(request)
  end

  test "fails start when the handshake returns a server error" do
    Process.flag(:trap_exit, true)

    transport = fn _uri, _request, _options ->
      response = [
        Codec.encode_header(%Header{type: :error_response}),
        <<1::little-16, 13, "Invalid token">>,
        <<0xFFFF::little-16>>
      ]

      {:ok, IO.iodata_to_binary(response)}
    end

    assert {:error, %QuackDB.Error{code: :server_error, message: "Invalid token"}} =
             QuackDB.Connection.start_link(uri: "http://localhost:9494", transport: transport)
  end
end

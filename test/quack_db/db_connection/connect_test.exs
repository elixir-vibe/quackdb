defmodule QuackDB.DBConnection.ConnectTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header

  import QuackDB.TestTransports

  test "connect sends auth and client metadata then stores server metadata" do
    parent = self()

    transport = fn _uri, request, _options ->
      assert {:ok, {%Header{type: :connection_request}, %ConnectionRequest{} = body}} =
               request |> IO.iodata_to_binary() |> Codec.decode()

      send(parent, {:connection_request, body})
      {:ok, connection_response()}
    end

    assert {:ok, state} =
             QuackDB.DBConnection.connect(
               uri: "quack://localhost:9494",
               token: "secret",
               client_version: "quackdb/test",
               transport: transport
             )

    assert state.uri.scheme == "http"
    assert state.uri.path == "/quack"
    assert state.connection_id == "conn-1"
    assert state.server.server_duckdb_version == "1.5.0"
    assert state.server.server_platform == "darwin"
    assert state.server.quack_version == 1

    assert_received {:connection_request,
                     %ConnectionRequest{
                       auth_string: "secret",
                       client_duckdb_version: "quackdb/test",
                       client_platform: platform
                     }}

    assert is_binary(platform)
    assert platform != ""
  end

  test "connect returns client URI validation errors" do
    assert {:error, %QuackDB.Error{} = error} =
             QuackDB.DBConnection.connect(
               uri: "ftp://localhost",
               transport: fn _, _, _ -> :ok end
             )

    assert error.code == :invalid_uri
    assert error.source == :client
    assert error.message == ~S[unsupported Quack URI scheme "ftp"]
  end

  test "connect returns transport errors" do
    error = QuackDB.Error.new(:transport_error, "connection refused", source: :transport)

    assert {:error, ^error} =
             QuackDB.DBConnection.connect(transport: fn _, _, _ -> {:error, error} end)
  end

  test "connect returns server error responses such as bad tokens" do
    transport = fn _, _, _ -> {:ok, QuackDB.ProtocolFixtures.error_response("invalid token")} end

    assert {:error, %QuackDB.Error{} = error} = QuackDB.DBConnection.connect(transport: transport)
    assert error.code == :server_error
    assert error.source == :server
    assert error.message == "invalid token"
  end

  test "connect returns protocol errors for malformed responses" do
    transport = fn _, _, _ -> {:ok, <<1, 2, 3>>} end

    assert {:error, %QuackDB.Error{} = error} = QuackDB.DBConnection.connect(transport: transport)
    assert error.source == :protocol
    assert error.message =~ "unknown message header field"
  end

  test "connect rejects unexpected response message types" do
    transport = fn _, _, _ -> {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [])} end

    assert {:error, %QuackDB.Error{} = error} = QuackDB.DBConnection.connect(transport: transport)
    assert error.code == :unexpected_message
    assert error.source == :protocol
    assert error.message == "expected connection response, got prepare_response"
  end
end

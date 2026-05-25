defmodule QuackDB.DBConnection.LifecycleTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

  import QuackDB.TestTransports

  test "connection remains usable after a server query error outside transactions" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    transport = fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT broken"}}} ->
          send(parent, :failed_query)
          {:ok, QuackDB.ProtocolFixtures.error_response("syntax error")}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT 1 AS n"}}} ->
          send(parent, :recovery_query)
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk])}
      end
    end

    connection = start_supervised!({QuackDB, transport: transport})

    assert {:error, %QuackDB.Error{message: "syntax error", query: "SELECT broken"}} =
             QuackDB.query(connection, "SELECT broken")

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1 AS n")

    assert_received :failed_query
    assert_received :recovery_query
  end

  test "disconnect sends best-effort disconnect when a connection id exists" do
    parent = self()
    {:ok, state} = QuackDB.DBConnection.connect(transport: disconnect_capture_transport(parent))

    assert :ok = QuackDB.DBConnection.disconnect(:shutdown, state)

    assert_received :disconnect
  end

  test "disconnect is a no-op before a connection id exists" do
    state = %QuackDB.DBConnection{connection_id: nil}

    assert :ok = QuackDB.DBConnection.disconnect(:shutdown, state)
  end

  defp disconnect_capture_transport(parent) do
    fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :disconnect_message}, _body}} ->
          send(parent, :disconnect)
          {:ok, connection_response()}
      end
    end
  end
end

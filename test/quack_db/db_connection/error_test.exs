defmodule QuackDB.DBConnection.ErrorTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

  import QuackDB.TestTransports

  test "attaches query and connection context to server errors" do
    connection = start_supervised!({QuackDB, transport: transport_error("syntax error")})

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELECT")
    assert error.message == "syntax error"
    assert error.query == "SELECT"
    assert error.connection_id == "conn-1"
    assert Exception.message(error) =~ "query: SELECT"
    assert Exception.message(error) =~ "connection_id: conn-1"
  end

  test "attaches query and connection context to transport errors during query" do
    connection = start_supervised!({QuackDB, transport: query_transport_error()})

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELECT 1")
    assert error.code == :transport_error
    assert error.source == :transport
    assert error.message == "connection reset"
    assert error.query == "SELECT 1"
    assert error.connection_id == "conn-1"
  end

  test "attaches query and connection context to protocol decode errors during query" do
    connection = start_supervised!({QuackDB, transport: malformed_query_response_transport()})

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELECT 1")
    assert error.source == :protocol
    assert error.message =~ "unknown message header field"
    assert error.query == "SELECT 1"
    assert error.connection_id == "conn-1"
  end

  test "unexpected query response types have stable messages and context" do
    connection = start_supervised!({QuackDB, transport: unexpected_query_response_transport()})

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELECT 1")
    assert error.code == :unexpected_message
    assert error.source == :protocol
    assert error.message == "expected prepare response, got fetch_response"
    assert error.query == "SELECT 1"
    assert error.connection_id == "conn-1"
  end

  test "stream open server errors are annotated with query and connection context" do
    connection = start_supervised!({QuackDB, transport: stream_open_error_transport()})

    error =
      assert_raise QuackDB.Error, fn ->
        DBConnection.transaction(connection, fn transaction_connection ->
          transaction_connection
          |> QuackDB.rows("SELECT broken_stream")
          |> Enum.to_list()
        end)
      end

    assert error.message == "open failed"
    assert error.query == "SELECT broken_stream"
    assert error.connection_id == "conn-1"
  end

  test "stream fetch server errors are annotated with query and connection context" do
    initial_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    connection =
      start_supervised!({QuackDB, transport: stream_fetch_error_transport(initial_chunk)})

    error =
      assert_raise QuackDB.Error, fn ->
        DBConnection.transaction(connection, fn transaction_connection ->
          transaction_connection
          |> QuackDB.rows("SELECT n")
          |> Enum.to_list()
        end)
      end

    assert error.message == "fetch failed"
    assert error.query == "SELECT n"
    assert error.connection_id == "conn-1"
  end

  test "exception message includes only present context" do
    error = QuackDB.Error.new(:transport_error, "connection refused", source: :transport)

    assert Exception.message(error) == "connection refused"

    error = %QuackDB.Error{error | query: "SELECT 1", connection_id: "conn-1"}

    assert Exception.message(error) ==
             "connection refused\n\n    query: SELECT 1\n    connection_id: conn-1"
  end

  test "inspect output is compact and includes useful fields" do
    error = %QuackDB.Error{
      QuackDB.Error.new(:server_error, String.duplicate("x", 200), source: :server)
      | query: String.duplicate("SELECT ", 50),
        connection_id: "abcdefghijklmnopqrstuvwxyz"
    }

    inspected = inspect(error)

    assert inspected =~ "QuackDB.Error"
    assert inspected =~ "code: :server_error"
    assert inspected =~ "source: :server"
    assert inspected =~ "connection_id: \"abcdefghijkl…\""
    assert String.length(inspected) < 320
  end

  defp query_transport_error do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:error, QuackDB.Error.new(:transport_error, "connection reset", source: :transport)}
      end
    end
  end

  defp malformed_query_response_transport do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok, <<1, 2, 3>>}
      end
    end
  end

  defp unexpected_query_response_transport do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok, QuackDB.ProtocolFixtures.fetch_response([])}
      end
    end
  end

  defp stream_open_error_transport do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [])}

        {:ok,
         {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT broken_stream"}}} ->
          {:ok, QuackDB.ProtocolFixtures.error_response("open failed")}
      end
    end
  end

  defp stream_fetch_error_transport(initial_chunk) do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT n"}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [initial_chunk],
             needs_more_fetch?: true,
             result_uuid: 42
           )}

        {:ok, {%Header{type: :fetch_request}, _fetch}} ->
          {:ok, QuackDB.ProtocolFixtures.error_response("fetch failed")}
      end
    end
  end
end

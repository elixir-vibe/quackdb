defmodule QuackDB.ConnectionTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Writer

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

  test "materializes rows from prepare responses" do
    transport = fn _uri, _request, _options ->
      response = [
        Codec.encode_header(%Header{type: :prepare_response, connection_id: "conn-1"}),
        Writer.field(1, Writer.list([integer_type()], &Function.identity/1)),
        Writer.field(2, Writer.list(["n"], &Writer.string/1)),
        Writer.field(3, Writer.bool(false)),
        Writer.field(
          4,
          Writer.list([integer_chunk_wrapper([1])], &Writer.nullable(&1, fn chunk -> chunk end))
        ),
        Writer.field(5, Writer.hugeint(42)),
        Writer.end_object()
      ]

      {:ok, IO.iodata_to_binary(response)}
    end

    connection =
      start_supervised!(
        {QuackDB.Connection, uri: "http://localhost:9494", connect: false, transport: transport}
      )

    :sys.replace_state(connection, &%{&1 | connection_id: "conn-1"})

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
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

  defp integer_type do
    [Writer.field(100, Writer.uleb128(LogicalType.id(:integer))), Writer.end_object()]
  end

  defp integer_chunk_wrapper(values) do
    [Writer.field(300, integer_chunk(values)), Writer.end_object()]
  end

  defp integer_chunk(values) do
    [
      Writer.field(100, Writer.uleb128(length(values))),
      Writer.field(101, Writer.list([integer_type()], &Function.identity/1)),
      Writer.field(102, Writer.list([integer_vector(values)], &Function.identity/1)),
      Writer.end_object()
    ]
  end

  defp integer_vector(values) do
    payload = for value <- values, into: <<>>, do: <<value::little-signed-32>>

    [
      Writer.field(100, Writer.bool(false)),
      Writer.field(102, Writer.blob(payload)),
      Writer.end_object()
    ]
  end
end

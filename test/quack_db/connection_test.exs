defmodule QuackDB.ConnectionTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.FetchRequest
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

      {:ok, QuackDB.ProtocolFixtures.error_response("syntax error")}
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
      chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
      {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk])}
    end

    connection =
      start_supervised!(
        {QuackDB.Connection, uri: "http://localhost:9494", connect: false, transport: transport}
      )

    :sys.replace_state(connection, &%{&1 | connection_id: "conn-1"})

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
  end

  test "fetches remaining chunks when prepare response requires more data" do
    parent = self()
    initial_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
    fetched_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2, 3])

    fetch_agent = start_supervised!({Agent, fn -> 0 end})

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)
      send(parent, {:request, request})

      if match?({:ok, {%Header{type: :fetch_request}, %FetchRequest{}}}, Codec.decode(request)) do
        fetch_count = Agent.get_and_update(fetch_agent, &{&1, &1 + 1})
        chunks = if fetch_count == 0, do: [fetched_chunk], else: []
        {:ok, QuackDB.ProtocolFixtures.fetch_response(chunks, batch_index: fetch_count)}
      else
        {:ok,
         QuackDB.ProtocolFixtures.prepare_response(
           chunks: [initial_chunk],
           needs_more_fetch?: true,
           result_uuid: 123
         )}
      end
    end

    connection =
      start_supervised!(
        {QuackDB.Connection, uri: "http://localhost:9494", connect: false, transport: transport}
      )

    :sys.replace_state(connection, &%{&1 | connection_id: "conn-1"})

    assert {:ok, %QuackDB.Result{rows: [[1], [2], [3]], num_rows: 3}} =
             QuackDB.query(connection, "SELECT n FROM numbers")

    assert_received {:request, prepare_request}
    assert_received {:request, fetch_request}
    assert {:ok, {%Header{type: :prepare_request}, _}} = Codec.decode(prepare_request)

    assert {:ok, {%Header{type: :fetch_request}, %FetchRequest{uuid: 123}}} =
             Codec.decode(fetch_request)
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

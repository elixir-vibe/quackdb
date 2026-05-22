defmodule QuackDB.DBConnectionTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

  test "prepare_execute returns query metadata and result" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
    connection = start_supervised!({QuackDB, transport: transport(prepare: [chunk])})

    assert {:ok, %QuackDB.Query{} = query, %QuackDB.Result{} = result} =
             QuackDB.prepare_execute(connection, "SELECT 1 AS n")

    assert query.columns == ["n"]
    assert query.result_uuid == 42
    assert result.rows == [[1]]
    assert result.command == :select
    assert result.connection_id == "conn-1"
    assert result.messages == []
  end

  test "query supports decode_mapper like Postgrex" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1, 2])
    connection = start_supervised!({QuackDB, transport: transport(prepare: [chunk])})

    assert {:ok, %QuackDB.Result{rows: [%{n: 1}, %{n: 2}]}} =
             QuackDB.query(connection, "SELECT n", [], decode_mapper: fn [n] -> %{n: n} end)
  end

  test "attaches query and connection context to server errors" do
    connection = start_supervised!({QuackDB, transport: transport_error("syntax error")})

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELECT")
    assert error.message == "syntax error"
    assert error.query == "SELECT"
    assert error.connection_id == "conn-1"
    assert Exception.message(error) =~ "query: SELECT"
  end

  test "formats parameters as SQL literals before sending Quack prepare requests" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    connection =
      start_supervised!({QuackDB, transport: transport(parent: parent, prepare: [chunk])})

    assert {:ok, %QuackDB.Result{rows: [[1]]}} =
             QuackDB.query(connection, "SELECT ? AS n", ["Robert'); DROP TABLE users;--"])

    assert_received {:statement, "SELECT 'Robert''); DROP TABLE users;--' AS n"}
  end

  test "DBConnection transactions issue BEGIN and COMMIT" do
    parent = self()
    connection = start_supervised!({QuackDB, transport: transport(parent: parent, prepare: [])})

    assert {:ok, :done} =
             DBConnection.transaction(connection, fn transaction_connection ->
               assert DBConnection.status(transaction_connection) == :transaction
               :done
             end)

    assert_received {:statement, "BEGIN"}
    assert_received {:statement, "COMMIT"}
  end

  test "rows and maps stream row-level results" do
    initial_chunk = QuackDB.ProtocolFixtures.scalar_chunk_wrapper([{:integer, :int32, [1]}])
    fetched_chunk = QuackDB.ProtocolFixtures.scalar_chunk_wrapper([{:integer, :int32, [2]}])

    rows_connection =
      start_supervised!(
        {QuackDB, transport: stream_transport(initial_chunk, fetched_chunk)},
        id: {QuackDB, :rows_stream}
      )

    assert {:ok, rows} =
             DBConnection.transaction(rows_connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.rows("SELECT n", [], max_rows: 1)
               |> Enum.to_list()
             end)

    assert rows == [[1], [2]]

    maps_connection =
      start_supervised!(
        {QuackDB, transport: stream_transport(initial_chunk, fetched_chunk)},
        id: {QuackDB, :maps_stream}
      )

    assert {:ok, maps} =
             DBConnection.transaction(maps_connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.maps("SELECT n", [], max_rows: 1)
               |> Enum.to_list()
             end)

    assert maps == [%{"n" => 1}, %{"n" => 2}]
  end

  test "stream returns result batches" do
    initial_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
    fetched_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])

    connection =
      start_supervised!({QuackDB, transport: stream_transport(initial_chunk, fetched_chunk)})

    assert {:ok, [%QuackDB.Result{rows: [[1]]}, %QuackDB.Result{rows: [[2]]}]} =
             DBConnection.transaction(connection, fn transaction_connection ->
               QuackDB.stream(transaction_connection, "SELECT n", [], max_rows: 1)
               |> Enum.to_list()
             end)
  end

  defp transport(options) do
    parent = Keyword.get(options, :parent)
    prepare_chunks = Keyword.fetch!(options, :prepare)

    fn _uri, request, _request_options ->
      request
      |> IO.iodata_to_binary()
      |> decode_request(parent)
      |> case do
        :connection ->
          {:ok, connection_response()}

        {:prepare, _statement} ->
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: prepare_chunks)}
      end
    end
  end

  defp transport_error(message) do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok, QuackDB.ProtocolFixtures.error_response(message)}
      end
    end
  end

  defp stream_transport(initial_chunk, fetched_chunk) do
    fetch_agent = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})

    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [initial_chunk],
             needs_more_fetch?: true,
             result_uuid: 42
           )}

        {:ok, {%Header{type: :fetch_request}, _body}} ->
          fetch_count = Agent.get_and_update(fetch_agent, &{&1, &1 + 1})
          chunks = if fetch_count == 0, do: [fetched_chunk], else: []
          {:ok, QuackDB.ProtocolFixtures.fetch_response(chunks, batch_index: fetch_count)}
      end
    end
  end

  defp decode_request(request, parent) do
    case Codec.decode(request) do
      {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
        :connection

      {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}} ->
        if parent, do: send(parent, {:statement, statement})
        {:prepare, statement}
    end
  end

  defp connection_response do
    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
      <<1::little-16, 5, "1.5.0">>,
      <<2::little-16, 6, "darwin">>,
      <<3::little-16, 1>>,
      <<0xFFFF::little-16>>
    ])
  end
end

defmodule QuackDB.DBConnection.StreamTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

  import QuackDB.TestTransports

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

  test "maps disambiguates duplicate column names" do
    chunk =
      QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
        {:integer, :int32, [1]},
        {:integer, :int32, [2]},
        {:integer, :int32, [3]}
      ])

    connection =
      start_supervised!({QuackDB, transport: transport(prepare: [chunk], names: ["x", "x", "x"])})

    assert {:ok, maps} =
             DBConnection.transaction(connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.maps("SELECT 1 AS x, 2 AS x, 3 AS x")
               |> Enum.to_list()
             end)

    assert maps == [%{"x" => 1, "x_2" => 2, "x_3" => 3}]
  end

  test "stream halts early without fetching remaining chunks" do
    parent = self()
    initial_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1, 2])
    fetched_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([3, 4])

    connection =
      start_supervised!(
        {QuackDB, transport: stream_transport(initial_chunk, fetched_chunk, parent: parent)}
      )

    assert {:ok, rows} =
             DBConnection.transaction(connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.rows("SELECT n")
               |> Enum.take(1)
             end)

    assert rows == [[1]]
    refute_received {:fetch, _count}
  end

  test "stream raises later fetch errors" do
    initial_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    connection =
      start_supervised!(
        {QuackDB, transport: stream_error_transport(initial_chunk, "fetch failed")}
      )

    assert_raise QuackDB.Error, ~r/fetch failed/, fn ->
      DBConnection.transaction(connection, fn transaction_connection ->
        transaction_connection
        |> QuackDB.rows("SELECT n")
        |> Enum.to_list()
      end)
    end
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

  test "same connection can run repeated streams" do
    parent = self()
    connection = start_supervised!({QuackDB, transport: repeated_stream_transport(parent)})

    assert {:ok, [[1], [2]]} =
             DBConnection.transaction(connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.rows("SELECT n", [], max_rows: 1)
               |> Enum.to_list()
             end)

    assert {:ok, [[1], [2]]} =
             DBConnection.transaction(connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.rows("SELECT n", [], max_rows: 1)
               |> Enum.to_list()
             end)

    assert_received {:prepare, 1}
    assert_received {:fetch, 1, 0}
    assert_received {:fetch, 1, 1}
    assert_received {:prepare, 2}
    assert_received {:fetch, 2, 0}
    assert_received {:fetch, 2, 1}
  end

  test "normal queries work before and after streams" do
    connection = start_supervised!({QuackDB, transport: query_and_stream_transport()})

    assert {:ok, %QuackDB.Result{rows: [[10]]}} = QuackDB.query(connection, "SELECT 10 AS n")

    assert {:ok, [[1], [2]]} =
             DBConnection.transaction(connection, fn transaction_connection ->
               transaction_connection
               |> QuackDB.rows("SELECT stream_n", [], max_rows: 1)
               |> Enum.to_list()
             end)

    assert {:ok, %QuackDB.Result{rows: [[20]]}} = QuackDB.query(connection, "SELECT 20 AS n")
  end

  test "stream open errors leave connection usable outside transactions" do
    connection = start_supervised!({QuackDB, transport: stream_open_error_transport()})

    assert_raise QuackDB.Error, ~r/open failed/, fn ->
      DBConnection.transaction(connection, fn transaction_connection ->
        transaction_connection
        |> QuackDB.rows("SELECT broken_stream")
        |> Enum.to_list()
      end)
    end

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1 AS n")
  end

  test "stream fetch errors keep the connection usable after transaction cleanup" do
    initial_chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    connection =
      start_supervised!({QuackDB, transport: fetch_error_then_recovery_transport(initial_chunk)})

    assert_raise QuackDB.Error, ~r/fetch failed/, fn ->
      DBConnection.transaction(connection, fn transaction_connection ->
        transaction_connection
        |> QuackDB.rows("SELECT n")
        |> Enum.to_list()
      end)
    end

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1 AS n")
  end

  defp repeated_stream_transport(parent) do
    stream_id_agent = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})
    fetch_counts_agent = start_supervised!({Agent, fn -> %{} end}, id: {Agent, make_ref()})

    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          stream_id = Agent.get_and_update(stream_id_agent, fn id -> {id + 1, id + 1} end)
          send(parent, {:prepare, stream_id})

          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])],
             needs_more_fetch?: true,
             result_uuid: stream_id
           )}

        {:ok, {%Header{type: :fetch_request}, fetch}} ->
          stream_id = fetch.uuid

          fetch_count =
            Agent.get_and_update(fetch_counts_agent, fn counts ->
              count = Map.get(counts, stream_id, 0)
              {count, Map.put(counts, stream_id, count + 1)}
            end)

          send(parent, {:fetch, stream_id, fetch_count})

          chunks =
            if fetch_count == 0,
              do: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])],
              else: []

          {:ok, QuackDB.ProtocolFixtures.fetch_response(chunks, batch_index: fetch_count)}
      end
    end
  end

  defp query_and_stream_transport do
    fetched? = start_supervised!({Agent, fn -> false end}, id: {Agent, make_ref()})

    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT 10 AS n"}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([10])]
           )}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT stream_n"}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])],
             needs_more_fetch?: true,
             result_uuid: 42
           )}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT 20 AS n"}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([20])]
           )}

        {:ok, {%Header{type: :fetch_request}, _fetch}} ->
          already_fetched? = Agent.get_and_update(fetched?, &{&1, true})

          chunks =
            if already_fetched?,
              do: [],
              else: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])]

          {:ok, QuackDB.ProtocolFixtures.fetch_response(chunks)}
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

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT 1 AS n"}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])]
           )}
      end
    end
  end

  defp fetch_error_then_recovery_transport(initial_chunk) do
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

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT 1 AS n"}}} ->
          {:ok,
           QuackDB.ProtocolFixtures.prepare_response(
             chunks: [QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])]
           )}

        {:ok, {%Header{type: :fetch_request}, _fetch}} ->
          {:ok, QuackDB.ProtocolFixtures.error_response("fetch failed")}
      end
    end
  end
end

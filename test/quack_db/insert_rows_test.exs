defmodule QuackDB.InsertRowsTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.AppendRequest
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.SuccessResponse

  test "insert_rows appends row data over DBConnection" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, QuackDB.TestTransports.connection_response()}

        {:ok,
         {%Header{type: :append_request, connection_id: "conn-1"}, %AppendRequest{} = append}} ->
          send(parent, {:append, append})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    {:ok, conn} =
      QuackDB.start_link(
        uri: "http://localhost:9494",
        token: "secret",
        transport: transport
      )

    assert {:ok, result} =
             QuackDB.insert_rows(conn, "events", [
               [id: 1, name: "one", active: true],
               [id: 2, name: "two", active: false]
             ])

    assert result.command == :insert
    assert result.num_rows == 2

    assert_receive {:append, append}
    assert append.table_name == "events"
    assert append.schema_name == ""
    assert append.append_chunk.row_count == 2
    assert Enum.map(append.append_chunk.types, & &1.name) == [:integer, :varchar, :boolean]
  end

  test "insert_rows batches append requests" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, QuackDB.TestTransports.connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    {:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", transport: transport)

    assert {:ok, result} =
             QuackDB.insert_rows(
               conn,
               "events",
               [
                 [id: 1, name: "one"],
                 [id: 2, name: "two"],
                 [id: 3, name: "three"]
               ],
               batch_size: 2
             )

    assert result.num_rows == 3
    assert_receive {:append, %{append_chunk: %{row_count: 2}}}
    assert_receive {:append, %{append_chunk: %{row_count: 1}}}
  end

  test "insert_rows batches with types inferred from the full row set" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, QuackDB.TestTransports.connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    {:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", transport: transport)

    assert {:ok, %QuackDB.Result{num_rows: 2}} =
             QuackDB.insert_rows(
               conn,
               "events",
               [[id: 1, name: nil], [id: 2, name: "two"]],
               batch_size: 1
             )

    assert_receive {:append, %{append_chunk: first_chunk}}
    assert_receive {:append, %{append_chunk: second_chunk}}
    assert Enum.map(first_chunk.types, & &1.name) == [:integer, :varchar]
    assert Enum.map(second_chunk.types, & &1.name) == [:integer, :varchar]
  end

  test "insert_rows rejects invalid batch sizes" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, QuackDB.TestTransports.connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    {:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", transport: transport)

    assert {:error, %QuackDB.Error{code: :invalid_batch_size}} =
             QuackDB.insert_rows(conn, "events", [[id: 1]], batch_size: 0)

    refute_receive {:append, _append}
  end

  test "insert_rows accepts explicit columns for empty batches" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, QuackDB.TestTransports.connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    {:ok, conn} = QuackDB.start_link(uri: "http://localhost:9494", transport: transport)

    assert {:ok, result} =
             QuackDB.insert_rows(conn, "events", [], columns: [id: :integer, name: :varchar])

    assert result.num_rows == 0
    assert_receive {:append, append}
    assert append.append_chunk.row_count == 0
    assert Enum.map(append.append_chunk.types, & &1.name) == [:integer, :varchar]
  end
end

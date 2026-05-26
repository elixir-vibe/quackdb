defmodule QuackDB.InsertStreamTest do
  use ExUnit.Case, async: false

  import QuackDB.TestTransports

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.AppendRequest
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.SuccessResponse

  test "insert_stream appends enumerable rows in chunks" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append.append_chunk.row_count})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    start_supervised!(
      {QuackDB,
       uri: "http://localhost:9494", token: "secret", transport: transport, name: __MODULE__}
    )

    rows = Stream.map(1..3, &%{id: &1})

    assert {:ok, _result} = QuackDB.insert_stream(__MODULE__, "events", rows, chunk_every: 2)
    assert_receive {:append, 2}
    assert_receive {:append, 1}
  end

  test "insert_table appends Table.Reader-compatible data" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append.append_chunk.row_count})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    start_supervised!(
      {QuackDB,
       uri: "http://localhost:9494", token: "secret", transport: transport, name: __MODULE__.Table}
    )

    assert {:ok, _result} =
             QuackDB.insert_table(__MODULE__.Table, "events", %{
               id: [1, 2],
               name: ["duck", "goose"]
             })

    assert_receive {:append, 2}
  end
end

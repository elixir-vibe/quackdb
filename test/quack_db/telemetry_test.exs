defmodule QuackDB.TelemetryTest do
  use ExUnit.Case, async: false

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.ProtocolFixtures

  setup do
    handler_id = {__MODULE__, self()}
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:quackdb, :query, :start],
        [:quackdb, :query, :stop],
        [:quackdb, :append, :start],
        [:quackdb, :append, :stop],
        [:quackdb, :fetch, :start],
        [:quackdb, :fetch, :stop],
        [:custom, :quackdb, :query, :start],
        [:custom, :quackdb, :query, :stop]
      ],
      &__MODULE__.handle_event/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "emits query telemetry" do
    connection =
      start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport()})

    assert %QuackDB.Result{rows: [[1]]} =
             QuackDB.query!(connection, "SELECT ?", [1],
               telemetry_options: [request_id: "req-1"],
               telemetry_params: true
             )

    assert_received {:telemetry, [:quackdb, :query, :start], %{system_time: _}, metadata}
    assert metadata.query == "SELECT ?"
    assert metadata.params == [1]
    assert metadata.options == [request_id: "req-1"]
    assert metadata.connection_id == "conn-1"
    assert metadata.client_query_id == 1

    assert_received {:telemetry, [:quackdb, :fetch, :start], %{system_time: _}, metadata}
    assert metadata.result_uuid == 42
    assert metadata.connection_id == "conn-1"
    assert metadata.client_query_id == 1

    assert_received {:telemetry, [:quackdb, :fetch, :stop], %{duration: duration}, metadata}
    assert is_integer(duration)
    assert metadata.chunks == 0
    assert metadata.result == :ok
    assert is_integer(metadata.encode_duration)
    assert is_integer(metadata.transport_duration)
    assert is_integer(metadata.decode_duration)
    assert is_integer(metadata.normalize_duration)
    assert metadata.request_bytes > 0
    assert metadata.response_bytes > 0

    assert_received {:telemetry, [:quackdb, :query, :stop], %{duration: duration}, metadata}
    assert is_integer(duration)
    assert metadata.command == :select
    assert metadata.rows == 1
    assert metadata.result == :ok
    assert is_integer(metadata.encode_duration)
    assert is_integer(metadata.transport_duration)
    assert is_integer(metadata.decode_duration)
    assert is_integer(metadata.normalize_duration)
    assert metadata.request_bytes > 0
    assert metadata.response_bytes > 0
  end

  test "emits append telemetry" do
    connection =
      start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport()})

    assert %QuackDB.Result{num_rows: 2} =
             QuackDB.insert_rows!(connection, "events", [[id: 1], [id: 2]])

    assert_received {:telemetry, [:quackdb, :append, :start], %{system_time: _}, metadata}
    assert metadata.query == "APPEND events"
    assert metadata.table == "events"
    assert metadata.rows == 2
    assert metadata.batches == 1
    assert metadata.connection_id == "conn-1"
    assert metadata.client_query_id == 1

    assert_received {:telemetry, [:quackdb, :append, :stop], %{duration: duration}, metadata}
    assert is_integer(duration)
    assert metadata.command == :insert
    assert metadata.rows == 2
    assert metadata.result == :ok
    assert metadata.batches == 1
    assert is_integer(metadata.encode_duration)
    assert is_integer(metadata.transport_duration)
    assert is_integer(metadata.decode_duration)
    assert is_integer(metadata.append_duration)
    assert metadata.request_bytes > 0
    assert metadata.response_bytes > 0
    assert metadata.rows_per_second > 0
  end

  test "supports custom telemetry prefixes" do
    connection =
      start_supervised!(
        {QuackDB,
         uri: "http://localhost:9494",
         transport: transport(),
         telemetry_prefix: [:custom, :quackdb]}
      )

    assert %QuackDB.Result{rows: [[1]]} = QuackDB.query!(connection, "SELECT 1")

    assert_received {:telemetry, [:custom, :quackdb, :query, :start], %{system_time: _}, metadata}
    assert metadata.query == "SELECT 1"

    assert_received {:telemetry, [:custom, :quackdb, :query, :stop], %{duration: duration},
                     metadata}

    assert is_integer(duration)
    assert metadata.command == :select
  end

  def handle_event(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  defp transport do
    fn _uri, request, options ->
      case request |> IO.iodata_to_binary() |> Codec.decode() do
        {:ok, {%Header{type: :connection_request}, _body}} ->
          response = [
            Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
            <<1::little-16, 5, "1.5.0">>,
            <<2::little-16, 6, "darwin">>,
            <<3::little-16, 1>>,
            <<0xFFFF::little-16>>
          ]

          {:ok, IO.iodata_to_binary(response)}

        {:ok, {%Header{type: :prepare_request, client_query_id: query_id}, _request}} ->
          assert Keyword.fetch!(options, :client_query_id) == query_id
          chunk = ProtocolFixtures.scalar_chunk_wrapper([{:integer, :int32, [1]}])

          {:ok,
           ProtocolFixtures.prepare_response(
             chunks: [chunk],
             names: ["one"],
             needs_more_fetch?: true
           )}

        {:ok, {%Header{type: :fetch_request}, _request}} ->
          {:ok, ProtocolFixtures.fetch_response([])}

        {:ok, {%Header{type: :append_request, client_query_id: query_id}, _request}} ->
          assert Keyword.fetch!(options, :client_query_id) == query_id

          response =
            Codec.encode(%QuackDB.Protocol.Message.SuccessResponse{}, connection_id: "conn-1")

          {:ok, IO.iodata_to_binary(response)}
      end
    end
  end
end

defmodule QuackDB.Protocol.CodecTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.Acknowledgement
  alias QuackDB.Protocol.Message.CancelRequest
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.FetchRequest
  alias QuackDB.Protocol.Message.FetchResponse
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.HeartbeatRequest
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message.PrepareRequest
  alias QuackDB.Protocol.Message.PrepareResponse
  alias QuackDB.Protocol.Message.SendDataRequest
  alias QuackDB.Protocol.Message.SendDataResponse
  alias QuackDB.Protocol.Vector
  alias QuackDB.Protocol.Writer

  test "connection requests advertise protocol version 3 and a heartbeat lease" do
    message = %ConnectionRequest{
      auth_string: "token",
      client_duckdb_version: "quackdb/dev",
      client_id: "worker-1",
      heartbeat_timeout_seconds: 30
    }

    binary = IO.iodata_to_binary(Codec.encode(message))

    assert {:ok, {%Header{type: :connection_request, client_query_id: nil}, ^message}} =
             Codec.decode(binary)

    assert message.min_supported_quack_version == 3
    assert message.max_supported_quack_version == 3
  end

  test "omits default-valued fields like DuckDB's serializer" do
    binary = IO.iodata_to_binary(Codec.encode(%ConnectionRequest{client_platform: ""}))

    assert {:ok, {_header, %ConnectionRequest{auth_string: "", client_id: ""}}} =
             Codec.decode(binary)

    refute binary =~ <<6::little-16>>
  end

  test "prepare requests carry the query uuid and inline row limit" do
    uuid = 123_456_789_012_345_678_901_234_567_890
    message = %PrepareRequest{sql_query: "SELECT 1", query_uuid: uuid, inline_rows: 0}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok, {%Header{type: :prepare_request, connection_id: "conn-1"}, ^message}} =
             Codec.decode(binary)
  end

  test "prepare requests leave the inline row limit to the server by default" do
    message = %PrepareRequest{sql_query: "SELECT 1", query_uuid: 7}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok, {_header, %PrepareRequest{inline_rows: nil}}} = Codec.decode(binary)
  end

  test "fetch requests name their batch and acknowledged prefix" do
    message = %FetchRequest{query_uuid: 42, batch_index: 3, ack_index: 2}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok, {%Header{type: :fetch_request}, ^message}} = Codec.decode(binary)
  end

  test "fetch responses carry their chunks as a blob after the body" do
    {:ok, chunk} = DataChunk.from_rows([[id: 1, name: "duck"], [id: 2, name: nil]])
    message = %FetchResponse{results: [chunk, chunk], batch_index: 1}
    binary = IO.iodata_to_binary(Codec.encode(message))

    assert {:ok, {%Header{type: :fetch_response}, %FetchResponse{} = decoded}} =
             Codec.decode(binary)

    assert decoded.batch_index == 1
    assert decoded.total_batches == nil

    assert Enum.map(decoded.results, &DataChunk.rows/1) ==
             List.duplicate([[1, "duck"], [2, nil]], 2)
  end

  test "terminal fetch responses carry the batch count and no chunks" do
    binary = IO.iodata_to_binary(Codec.encode(%FetchResponse{total_batches: 4}))

    assert {:ok, {_header, %FetchResponse{results: [], total_batches: 4}}} = Codec.decode(binary)
  end

  test "send-data requests round-trip their chunk blob" do
    {:ok, chunk} = DataChunk.from_rows([[id: 1], [id: 2]])
    message = %SendDataRequest{stream_id: "stream-1", batch_index: 1, chunks: [chunk]}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok, {%Header{type: :send_data_request}, %SendDataRequest{} = decoded}} =
             Codec.decode(binary)

    assert decoded.stream_id == "stream-1"
    assert decoded.batch_index == 1
    assert [[[1], [2]]] = Enum.map(decoded.chunks, &DataChunk.rows/1)
  end

  test "terminal send-data requests close the stream against its batch count" do
    message = %SendDataRequest{stream_id: "stream-1", total_batches: 2}
    binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))

    assert {:ok, {_header, %SendDataRequest{chunks: [], batch_index: nil, total_batches: 2}}} =
             Codec.decode(binary)
  end

  test "decodes send-data responses" do
    binary = IO.iodata_to_binary(Codec.encode(%SendDataResponse{}))

    assert {:ok, {%Header{type: :send_data_response}, %SendDataResponse{accept_budget: nil}}} =
             Codec.decode(binary)
  end

  test "round-trips cancel, acknowledgement, and heartbeat requests" do
    for message <- [
          %CancelRequest{query_uuid: 9},
          %CancelRequest{query_uuid: 0},
          %Acknowledgement{query_uuid: 9},
          %HeartbeatRequest{}
        ] do
      binary = IO.iodata_to_binary(Codec.encode(message, connection_id: "conn-1"))
      assert {:ok, {%Header{connection_id: "conn-1"}, ^message}} = Codec.decode(binary)
    end
  end

  test "decodes connection response messages" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
        <<1::little-16, 6, "v2.0.0">>,
        <<2::little-16, 6, "darwin">>,
        <<3::little-16, 3>>,
        <<4::little-16, 60>>,
        <<0xFFFF::little-16>>
      ])

    assert {:ok,
            {%Header{type: :connection_response, connection_id: "conn-1"},
             %ConnectionResponse{
               server_duckdb_version: "v2.0.0",
               server_platform: "darwin",
               quack_version: 3,
               heartbeat_timeout_seconds: 60
             }}} = Codec.decode(binary)
  end

  test "round-trips typed error responses" do
    message = %ErrorResponse{
      message: "Table with name nope does not exist!",
      exception_type: "Catalog",
      extra_info: %{"name" => "nope", "type" => "Table", "empty" => ""},
      must_invalidate: true
    }

    binary = IO.iodata_to_binary(Codec.encode(message))

    assert {:ok, {%Header{type: :error_response}, ^message}} = Codec.decode(binary)
  end

  test "decodes error responses that only carry a message" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :error_response, connection_id: "conn-1"}),
        <<1::little-16, 13, "Invalid token">>,
        <<0xFFFF::little-16>>
      ])

    assert {:ok,
            {%Header{type: :error_response},
             %ErrorResponse{message: "Invalid token", exception_type: "", extra_info: %{}}}} =
             Codec.decode(binary)
  end

  test "reports unknown message types" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :invalid}),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unsupported_message_type, message: message}} =
             Codec.decode(binary)

    assert message == "decoding invalid messages is not supported"
  end

  test "reports unknown message type ids" do
    binary =
      IO.iodata_to_binary([
        Writer.field(1, Writer.uleb128(999_999)),
        Writer.end_object(),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_message_type, message: message}} =
             Codec.decode(binary)

    assert message == "unknown Quack message type 999999"
  end

  test "reports unknown header fields" do
    binary =
      IO.iodata_to_binary([
        Writer.field(999, Writer.uleb128(1)),
        Writer.end_object(),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_header_field, message: message}} =
             Codec.decode(binary)

    assert message == "unknown message header field 999"
  end

  test "reports unknown body fields" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :error_response}),
        Writer.field(9, Writer.string("unexpected")),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_error_response_field, message: message}} =
             Codec.decode(binary)

    assert message == "unknown error response field 9"
  end

  test "reports unexpected fields in empty message bodies" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :success_response}),
        Writer.field(1, Writer.string("unexpected")),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unexpected_body_field, message: message}} =
             Codec.decode(binary)

    assert message == "expected an empty message body"
  end

  test "reports trailing bytes after message bodies" do
    binary =
      IO.iodata_to_binary([
        Codec.encode(%ErrorResponse{message: "bad"}),
        <<0>>
      ])

    assert {:error, %QuackDB.Error{code: :trailing_bytes, message: message}} =
             Codec.decode(binary)

    assert message == "message has trailing bytes after the body"
  end

  test "reports a chunk blob shorter than its declared count" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :fetch_response}),
        Writer.field(1, Writer.uleb128(1)),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :truncated_field_id}} = Codec.decode(binary)
  end

  describe "copy_binaries/1" do
    test "copies every binary off the response, including nested values and column names" do
      types = [
        name: :varchar,
        tags: {:list, :varchar},
        meta: {:struct, [label: :varchar, score: :integer]},
        labels: {:map, :varchar, :varchar},
        id: :integer
      ]

      # Shorter binaries are copied out of the response when they are matched.
      long = String.duplicate("duck", 20)

      row = [
        name: long,
        tags: [long, "b"],
        meta: %{label: long, score: 1},
        labels: %{"env" => long},
        id: 7
      ]

      {:ok, chunk} = DataChunk.from_rows([row], columns: types)

      response =
        IO.iodata_to_binary(
          Codec.encode(%PrepareResponse{
            result_names: ["name", "tags", "meta", "labels", "id"],
            result_types: chunk.types,
            results: [chunk],
            query_uuid: 1
          })
        )

      {:ok, {_header, decoded}} = Codec.decode(response)
      copied = Codec.copy_binaries(decoded)

      assert copied == decoded

      assert Enum.any?(
               binaries(decoded),
               &(:binary.referenced_byte_size(&1) == byte_size(response))
             )

      assert Enum.all?(binaries(copied), &(:binary.referenced_byte_size(&1) == byte_size(&1)))
    end

    test "copies ENUM labels that decoded values share with the type" do
      high = String.duplicate("high", 20)
      type = LogicalType.new(:enum, %{type: 6, values_count: 2, values: ["low", high]})
      chunk = %DataChunk{row_count: 1, types: [type], columns: [%Vector{type: type, values: [1]}]}
      binary = chunk |> DataChunk.encode() |> IO.iodata_to_binary()

      {:ok, decoded, ""} = DataChunk.decode(binary)
      [[label]] = DataChunk.rows(decoded)
      assert label == high
      assert :binary.referenced_byte_size(label) == byte_size(binary)

      %FetchResponse{results: [copied]} = Codec.copy_binaries(%FetchResponse{results: [decoded]})
      [[copied_label]] = DataChunk.rows(copied)
      assert :binary.referenced_byte_size(copied_label) == byte_size(copied_label)
    end

    test "leaves other messages unchanged" do
      assert Codec.copy_binaries(%SendDataResponse{}) == %SendDataResponse{}
    end
  end

  defp binaries(term) when is_binary(term), do: [term]
  defp binaries(term) when is_list(term), do: Enum.flat_map(term, &binaries/1)
  defp binaries(%_{} = term), do: term |> Map.from_struct() |> binaries()

  defp binaries(term) when is_map(term),
    do: Enum.flat_map(term, fn {k, v} -> binaries(k) ++ binaries(v) end)

  defp binaries(_term), do: []
end

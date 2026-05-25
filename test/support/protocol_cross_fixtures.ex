defmodule QuackDB.ProtocolCrossFixtures do
  @moduledoc false

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.AppendRequest

  def all do
    [
      data_chunk_scalar(),
      data_chunk_nested(),
      append_request_scalar(),
      append_request_nested()
    ]
  end

  def data_chunk_scalar do
    %{name: "scalar DataChunk", file: "data_chunk_scalar.bin", encoder: :encode_scalar_data_chunk}
  end

  def data_chunk_nested do
    %{name: "nested DataChunk", file: "data_chunk_nested.bin", encoder: :encode_nested_data_chunk}
  end

  def append_request_scalar do
    %{
      name: "scalar AppendRequest",
      file: "append_request_scalar.bin",
      encoder: :encode_scalar_append_request
    }
  end

  def append_request_nested do
    %{
      name: "nested AppendRequest",
      file: "append_request_nested.bin",
      encoder: :encode_nested_append_request
    }
  end

  def encode_scalar_data_chunk do
    scalar_chunk()
    |> DataChunk.encode_wrapper()
    |> IO.iodata_to_binary()
  end

  def encode_nested_data_chunk do
    nested_chunk()
    |> DataChunk.encode_wrapper()
    |> IO.iodata_to_binary()
  end

  def encode_scalar_append_request do
    encode_append_request(scalar_chunk())
  end

  def encode_nested_append_request do
    encode_append_request(nested_chunk())
  end

  def scalar_chunk do
    rows = [
      [
        id: 1,
        name: "duck",
        active: true,
        amount: Decimal.new("123.45"),
        event_date: ~D[2026-05-25],
        event_time: ~T[12:34:56.123456],
        happened_at: ~N[2026-05-25 12:34:56.123456],
        happened_tz: ~U[2026-05-25 12:34:56.123456Z],
        payload: <<1, 2, 3>>
      ],
      [
        id: 2,
        name: nil,
        active: false,
        amount: Decimal.new("-1.25"),
        event_date: nil,
        event_time: ~T[00:00:00],
        happened_at: ~N[1970-01-01 00:00:00],
        happened_tz: nil,
        payload: <<>>
      ]
    ]

    columns = [
      id: :integer,
      name: :varchar,
      active: :boolean,
      amount: {:decimal, 8, 2},
      event_date: :date,
      event_time: :time,
      happened_at: :timestamp,
      happened_tz: :timestamp_tz,
      payload: :blob
    ]

    build_chunk!(rows, columns)
  end

  def nested_chunk do
    rows = [
      [
        id: 1,
        tags: ["duck", "analytics"],
        metadata: %{source: "sensor", count: 2},
        scores: [10, 20, 30],
        labels: [%{key: "env", value: "test"}]
      ],
      [
        id: 2,
        tags: [],
        metadata: %{source: "batch", count: nil},
        scores: [40, 50, 60],
        labels: nil
      ]
    ]

    columns = [
      id: :integer,
      tags: {:list, :varchar},
      metadata: {:struct, [source: :varchar, count: :integer]},
      scores: {:array, :integer, 3},
      labels: {:map, :varchar, :varchar}
    ]

    build_chunk!(rows, columns)
  end

  defp encode_append_request(chunk) do
    %AppendRequest{schema_name: "main", table_name: "events", append_chunk: chunk}
    |> Codec.encode(connection_id: "conn-1")
    |> IO.iodata_to_binary()
  end

  defp build_chunk!(rows, columns) do
    case DataChunk.from_rows(rows, columns: columns) do
      {:ok, chunk} -> chunk
      {:error, error} -> raise error
    end
  end
end

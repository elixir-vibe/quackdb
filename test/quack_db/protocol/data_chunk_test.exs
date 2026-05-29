defmodule QuackDB.Protocol.DataChunkTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType

  test "decodes flat integer data chunks" do
    binary = IO.iodata_to_binary(QuackDB.ProtocolFixtures.integer_chunk_wrapper([1, nil, 3]))

    assert {:ok, chunk, ""} = DataChunk.decode_wrapper(binary)
    assert [%LogicalType{name: :integer}] = chunk.types
    assert DataChunk.rows(chunk) == [[1], [nil], [3]]
  end

  test "encodes column-oriented values as a flat data chunk" do
    assert {:ok, chunk} =
             DataChunk.from_columns(
               [id: [1, 2], name: ["one", nil], active: [true, false]],
               columns: [id: :integer, name: :varchar, active: :boolean]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)
    assert Enum.map(decoded.types, & &1.name) == [:integer, :varchar, :boolean]
    assert DataChunk.rows(decoded) == [[1, "one", true], [2, nil, false]]
  end

  test "encodes column-oriented explicit map values from ordinary Elixir maps" do
    assert {:ok, chunk} =
             DataChunk.from_columns(
               [labels: [%{env: "prod", region: "eu"}, %{env: nil}, %{}, nil]],
               columns: [labels: {:map, :varchar, :varchar}]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)

    assert DataChunk.rows(decoded) == [
             [%{"env" => "prod", "region" => "eu"}],
             [%{"env" => nil}],
             [%{}],
             [nil]
           ]
  end

  test "rejects mismatched append column lengths" do
    assert {:error, %QuackDB.Error{code: :invalid_vector_size, message: message}} =
             DataChunk.from_columns(
               [id: [1, 2], name: ["one"]],
               columns: [id: :integer, name: :varchar]
             )

    assert message =~ "mismatched row counts"
  end

  test "rejects missing append type inference for empty inputs" do
    assert {:error, %QuackDB.Error{code: :missing_append_columns}} =
             DataChunk.from_columns([], columns: [])

    assert {:error, %QuackDB.Error{code: :missing_append_columns}} =
             DataChunk.from_rows([])
  end

  test "encodes row maps as a flat data chunk" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [%{id: 1, name: "one", active: true}, %{id: 2, name: nil, active: false}],
               columns: [id: :integer, name: :varchar, active: :boolean]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)
    assert Enum.map(decoded.types, & &1.name) == [:integer, :varchar, :boolean]
    assert DataChunk.rows(decoded) == [[1, "one", true], [2, nil, false]]
  end

  test "infers ordered columns from keyword rows" do
    assert {:ok, chunk} =
             DataChunk.from_rows([
               [id: 1, name: "one", active: true],
               [id: 2, name: "two", active: false]
             ])

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)
    assert Enum.map(decoded.types, & &1.name) == [:integer, :varchar, :boolean]
    assert DataChunk.rows(decoded) == [[1, "one", true], [2, "two", false]]
  end

  test "encodes nested list struct array and map values" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [
                 [
                   tags: ["duck", "analytics"],
                   metadata: %{source: "sensor", count: 2},
                   scores: [10, 20, 30],
                   labels: [%{key: "env", value: "test"}]
                 ],
                 [
                   tags: [],
                   metadata: %{source: "batch", count: nil},
                   scores: [40, 50, 60],
                   labels: nil
                 ]
               ],
               columns: [
                 tags: {:list, :varchar},
                 metadata: {:struct, [source: :varchar, count: :integer]},
                 scores: {:array, :integer, 3},
                 labels: {:map, :varchar, :varchar}
               ]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)

    assert DataChunk.rows(decoded) == [
             [
               ["duck", "analytics"],
               %{"source" => "sensor", "count" => 2},
               [10, 20, 30],
               %{"env" => "test"}
             ],
             [[], %{"source" => "batch", "count" => nil}, [40, 50, 60], nil]
           ]
  end

  test "explicit map columns encode ordinary Elixir maps and key-value entries equivalently" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [
                 [labels: %{env: "test", region: "eu"}],
                 [labels: [%{key: "env", value: "test"}, %{key: "region", value: "eu"}]],
                 [labels: %{env: nil}],
                 [labels: %{}],
                 [labels: nil]
               ],
               columns: [labels: {:map, :varchar, :varchar}]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)

    assert DataChunk.rows(decoded) == [
             [%{"env" => "test", "region" => "eu"}],
             [%{"env" => "test", "region" => "eu"}],
             [%{"env" => nil}],
             [%{}],
             [nil]
           ]
  end

  test "explicit map columns decode duplicate keys with last entry winning" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [[labels: [%{key: "env", value: "dev"}, %{key: "env", value: "prod"}]]],
               columns: [labels: {:map, :varchar, :varchar}]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)
    assert DataChunk.rows(decoded) == [[%{"env" => "prod"}]]
  end

  test "explicit map columns coerce atom keys through the declared key type" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [[labels: %{env: "prod", region: "eu"}]],
               columns: [labels: {:map, :varchar, :varchar}]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)
    assert DataChunk.rows(decoded) == [[%{"env" => "prod", "region" => "eu"}]]
  end

  test "ordinary Elixir maps encode inside nested explicit map types" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [
                 [metadata: %{source: "sensor", labels: %{env: "prod"}}],
                 [metadata: %{source: "batch", labels: nil}]
               ],
               columns: [
                 metadata: {:struct, [source: :varchar, labels: {:map, :varchar, :varchar}]}
               ]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)

    assert DataChunk.rows(decoded) == [
             [%{"source" => "sensor", "labels" => %{"env" => "prod"}}],
             [%{"source" => "batch", "labels" => nil}]
           ]
  end

  test "plain map inference remains struct-shaped" do
    assert {:ok, chunk} = DataChunk.from_rows([[labels: %{env: "test", region: "eu"}]])

    assert [%{name: :struct}] = chunk.types
  end

  test "encodes calendar date and time values through ISO calendar conversions" do
    assert {:ok, chunk} =
             DataChunk.from_rows(
               [
                 [
                   event_date: ~N[2026-05-25 12:34:56],
                   event_time: ~N[2026-05-25 12:34:56.123456],
                   happened_at: ~U[2026-05-25 12:34:56.123456Z],
                   happened_tz: ~U[2026-05-25 12:34:56.123456Z]
                 ]
               ],
               columns: [
                 event_date: :date,
                 event_time: :time,
                 happened_at: :timestamp,
                 happened_tz: :timestamp_tz
               ]
             )

    binary = IO.iodata_to_binary(DataChunk.encode_wrapper(chunk))

    assert {:ok, decoded, ""} = DataChunk.decode_wrapper(binary)

    assert DataChunk.rows(decoded) == [
             [
               ~D[2026-05-25],
               ~T[12:34:56.123456],
               ~N[2026-05-25 12:34:56.123456],
               ~U[2026-05-25 12:34:56.123456Z]
             ]
           ]
  end
end

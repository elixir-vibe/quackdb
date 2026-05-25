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
end

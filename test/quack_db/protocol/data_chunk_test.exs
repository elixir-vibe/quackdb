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
end

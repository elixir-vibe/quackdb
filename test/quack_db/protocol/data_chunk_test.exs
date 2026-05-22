defmodule QuackDB.Protocol.DataChunkTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Writer

  test "decodes flat integer data chunks" do
    binary = integer_chunk_wrapper([[1, nil, 3]])

    assert {:ok, chunk, ""} = DataChunk.decode_wrapper(binary)
    assert [%LogicalType{name: :integer}] = chunk.types
    assert DataChunk.rows(chunk) == [[1], [nil], [3]]
  end

  defp integer_chunk_wrapper([values]) do
    IO.iodata_to_binary([
      Writer.field(300, integer_chunk(values)),
      Writer.end_object()
    ])
  end

  defp integer_chunk(values) do
    [
      Writer.field(100, Writer.uleb128(length(values))),
      Writer.field(101, Writer.list([integer_type()], &Function.identity/1)),
      Writer.field(102, Writer.list([integer_vector(values)], &Function.identity/1)),
      Writer.end_object()
    ]
  end

  defp integer_type do
    [Writer.field(100, Writer.uleb128(LogicalType.id(:integer))), Writer.end_object()]
  end

  defp integer_vector(values) do
    validity = Enum.map(values, &(!is_nil(&1)))
    payload = for value <- values, into: <<>>, do: <<value || 0::little-signed-32>>

    [
      Writer.field(100, Writer.bool(true)),
      Writer.field(101, Writer.blob(validity_mask(validity))),
      Writer.field(102, Writer.blob(payload)),
      Writer.end_object()
    ]
  end

  defp validity_mask(validity) do
    byte =
      validity
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {true, index}, byte -> byte ||| 1 <<< index
        {false, _index}, byte -> byte
      end)

    <<byte, 0, 0, 0, 0, 0, 0, 0>>
  end
end

defmodule QuackDB.Protocol.PrepareResponseTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareResponse
  alias QuackDB.Protocol.Writer

  test "decodes prepare responses with initial result chunks" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :prepare_response, connection_id: "conn-1"}),
        Writer.field(1, Writer.list([integer_type()], &Function.identity/1)),
        Writer.field(2, Writer.list(["n"], &Writer.string/1)),
        Writer.field(3, Writer.bool(false)),
        Writer.field(
          4,
          Writer.list([integer_chunk_wrapper([1])], &Writer.nullable(&1, fn chunk -> chunk end))
        ),
        Writer.field(5, Writer.hugeint(42)),
        Writer.end_object()
      ])

    assert {:ok,
            {%Header{type: :prepare_response, connection_id: "conn-1"},
             %PrepareResponse{} = response}} =
             Codec.decode(binary)

    assert [%LogicalType{name: :integer}] = response.result_types
    assert response.result_names == ["n"]
    assert response.result_uuid == 42
    assert response.needs_more_fetch == false
    assert [chunk] = response.results
    assert QuackDB.Protocol.DataChunk.rows(chunk) == [[1]]
  end

  defp integer_type do
    [Writer.field(100, Writer.uleb128(LogicalType.id(:integer))), Writer.end_object()]
  end

  defp integer_chunk_wrapper(values) do
    [Writer.field(300, integer_chunk(values)), Writer.end_object()]
  end

  defp integer_chunk(values) do
    [
      Writer.field(100, Writer.uleb128(length(values))),
      Writer.field(101, Writer.list([integer_type()], &Function.identity/1)),
      Writer.field(102, Writer.list([integer_vector(values)], &Function.identity/1)),
      Writer.end_object()
    ]
  end

  defp integer_vector(values) do
    payload = for value <- values, into: <<>>, do: <<value::little-signed-32>>

    [
      Writer.field(100, Writer.bool(false)),
      Writer.field(102, Writer.blob(payload)),
      Writer.end_object()
    ]
  end
end

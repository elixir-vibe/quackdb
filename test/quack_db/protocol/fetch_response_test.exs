defmodule QuackDB.Protocol.FetchResponseTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.FetchResponse
  alias QuackDB.Protocol.Message.Header

  test "decodes fetch responses" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2, 3])
    binary = QuackDB.ProtocolFixtures.fetch_response([chunk], batch_index: 7)

    assert {:ok, {%Header{type: :fetch_response}, %FetchResponse{} = response}} =
             Codec.decode(binary)

    assert response.batch_index == 7
    assert [chunk] = response.results
    assert QuackDB.Protocol.DataChunk.rows(chunk) == [[2], [3]]
  end

  test "rejects null data chunk pointers" do
    binary =
      IO.iodata_to_binary([
        Codec.encode_header(%Header{type: :fetch_response, connection_id: "conn-1"}),
        QuackDB.Protocol.Writer.field(
          1,
          QuackDB.Protocol.Writer.list(
            [nil],
            &QuackDB.Protocol.Writer.nullable(&1, fn chunk -> chunk end)
          )
        ),
        QuackDB.Protocol.Writer.field(2, QuackDB.Protocol.Writer.optional_index(nil)),
        QuackDB.Protocol.Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :null_data_chunk}} = Codec.decode(binary)
  end
end

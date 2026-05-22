defmodule QuackDB.Protocol.PrepareResponseTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareResponse

  test "decodes prepare responses with initial result chunks" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
    binary = QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk])

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
end

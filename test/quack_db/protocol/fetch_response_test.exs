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
end

defmodule QuackDB.Protocol.VectorEncodingTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk

  test "decodes dictionary vectors" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        4,
        [QuackDB.ProtocolFixtures.integer_type()],
        [QuackDB.ProtocolFixtures.dictionary_integer_vector([2, 0, 1, 2], [10, 20, 30])]
      )
      |> then(&[QuackDB.Protocol.Writer.field(300, &1), QuackDB.Protocol.Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:ok, chunk, ""} = DataChunk.decode_wrapper(binary)
    assert DataChunk.rows(chunk) == [[30], [10], [20], [30]]
  end

  test "decodes sequence vectors" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        4,
        [QuackDB.ProtocolFixtures.integer_type()],
        [QuackDB.ProtocolFixtures.sequence_integer_vector(10, 5)]
      )
      |> then(&[QuackDB.Protocol.Writer.field(300, &1), QuackDB.Protocol.Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:ok, chunk, ""} = DataChunk.decode_wrapper(binary)
    assert DataChunk.rows(chunk) == [[10], [15], [20], [25]]
  end

  test "reports unsupported FSST vectors explicitly" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [QuackDB.ProtocolFixtures.integer_type()],
        [
          [
            QuackDB.Protocol.Writer.field(90, QuackDB.Protocol.Writer.uleb128(1)),
            QuackDB.Protocol.Writer.field(100, QuackDB.Protocol.Writer.bool(false)),
            QuackDB.Protocol.Writer.end_object()
          ]
        ]
      )
      |> then(&[QuackDB.Protocol.Writer.field(300, &1), QuackDB.Protocol.Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :unsupported_vector_type, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message =~ "fsst vectors are not implemented yet"
  end

  test "reports dictionary indexes outside the dictionary" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [QuackDB.ProtocolFixtures.integer_type()],
        [QuackDB.ProtocolFixtures.dictionary_integer_vector([1], [10])]
      )
      |> then(&[QuackDB.Protocol.Writer.field(300, &1), QuackDB.Protocol.Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :dictionary_index_out_of_range}} =
             DataChunk.decode_wrapper(binary)
  end
end

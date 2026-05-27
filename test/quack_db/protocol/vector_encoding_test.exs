defmodule QuackDB.Protocol.VectorEncodingTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Writer

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

  test "reports missing required validity fields" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [QuackDB.ProtocolFixtures.integer_type()],
        [[Writer.field(102, Writer.blob(<<1::little-signed-32>>)), Writer.end_object()]]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :unexpected_field, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "expected field 100, got 102"
  end

  test "reports fixed-size vector payload size mismatches" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        2,
        [QuackDB.ProtocolFixtures.integer_type()],
        [
          [
            Writer.field(100, Writer.bool(false)),
            Writer.field(102, Writer.blob(<<1::little-signed-32>>)),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :invalid_blob_size, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "expected 8 bytes, got 4"
  end

  test "reports invalid validity mask sizes" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        2,
        [QuackDB.ProtocolFixtures.integer_type()],
        [
          [
            Writer.field(100, Writer.bool(true)),
            Writer.field(101, Writer.blob(<<1>>)),
            Writer.field(102, Writer.blob(<<1::little-signed-32, 2::little-signed-32>>)),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :invalid_blob_size, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "expected 8 bytes, got 1"
  end

  test "reports list entry count mismatches" do
    list_type = LogicalType.new(:list, %{type: 4, child_type: LogicalType.new(:integer)})

    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        2,
        [LogicalType.encode(list_type)],
        [
          [
            Writer.field(100, Writer.bool(false)),
            Writer.field(104, Writer.uleb128(0)),
            Writer.field(105, Writer.list([%{offset: 0, length: 0}], &list_entry/1)),
            Writer.field(106, QuackDB.Protocol.Vector.encode(LogicalType.new(:integer), [], 0)),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :list_entry_count_mismatch, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "list vector serialized 1 entries for 2 rows"
  end

  test "reports list entry bounds violations" do
    list_type = LogicalType.new(:list, %{type: 4, child_type: LogicalType.new(:integer)})

    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [LogicalType.encode(list_type)],
        [
          [
            Writer.field(100, Writer.bool(false)),
            Writer.field(104, Writer.uleb128(1)),
            Writer.field(105, Writer.list([%{offset: 1, length: 1}], &list_entry/1)),
            Writer.field(106, QuackDB.Protocol.Vector.encode(LogicalType.new(:integer), [10], 1)),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :list_entry_out_of_bounds, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "list entry offset 1 with length 1 exceeds child vector size 1"
  end

  test "reports malformed map entries" do
    entry_type =
      LogicalType.new(:struct, %{
        type: 5,
        children: [%{name: "key", type: LogicalType.new(:varchar)}]
      })

    map_type = LogicalType.new(:map, %{type: 4, child_type: entry_type})

    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [LogicalType.encode(map_type)],
        [
          [
            Writer.field(100, Writer.bool(false)),
            Writer.field(104, Writer.uleb128(1)),
            Writer.field(105, Writer.list([%{offset: 0, length: 1}], &list_entry/1)),
            Writer.field(106, QuackDB.Protocol.Vector.encode(entry_type, [%{key: "env"}], 1)),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :invalid_map_entry, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == ~s|MAP entry must include key and value fields, got %{"key" => "env"}|
  end

  test "reports struct child count mismatches" do
    struct_type =
      LogicalType.new(:struct, %{
        type: 5,
        children: [
          %{name: "a", type: LogicalType.new(:integer)},
          %{name: "b", type: LogicalType.new(:integer)}
        ]
      })

    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [LogicalType.encode(struct_type)],
        [
          [
            Writer.field(100, Writer.bool(false)),
            Writer.field(
              103,
              Writer.list(
                [QuackDB.Protocol.Vector.encode(LogicalType.new(:integer), [1], 1)],
                &Function.identity/1
              )
            ),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :struct_child_mismatch, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "struct vector serialized 1 child vectors for 2 child types"
  end

  test "reports array size mismatches" do
    array_type =
      LogicalType.new(:array, %{type: 9, child_type: LogicalType.new(:integer), size: 3})

    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [LogicalType.encode(array_type)],
        [
          [
            Writer.field(100, Writer.bool(false)),
            Writer.field(103, Writer.uleb128(2)),
            Writer.field(
              104,
              QuackDB.Protocol.Vector.encode(LogicalType.new(:integer), [1, 2], 2)
            ),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :array_size_mismatch, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "array vector serialized size 2, expected 3"
  end

  test "reports dictionary selection size mismatches" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        2,
        [QuackDB.ProtocolFixtures.integer_type()],
        [
          [
            Writer.field(90, Writer.uleb128(3)),
            Writer.field(91, Writer.blob(<<0::little-unsigned-32>>)),
            Writer.field(92, Writer.uleb128(1)),
            QuackDB.ProtocolFixtures.integer_vector([10])
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :invalid_blob_size, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "expected 8 bytes, got 4"
  end

  test "reports sequence vectors missing increment" do
    binary =
      QuackDB.ProtocolFixtures.data_chunk(
        1,
        [QuackDB.ProtocolFixtures.integer_type()],
        [
          [
            Writer.field(90, Writer.uleb128(4)),
            Writer.field(91, Writer.sleb128(1)),
            Writer.end_object()
          ]
        ]
      )
      |> then(&[Writer.field(300, &1), Writer.end_object()])
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :unexpected_field, message: message}} =
             DataChunk.decode_wrapper(binary)

    assert message == "expected field 92, got 65535"
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

  defp list_entry(%{offset: offset, length: length}) do
    [
      Writer.field(100, Writer.uleb128(offset)),
      Writer.field(101, Writer.uleb128(length)),
      Writer.end_object()
    ]
  end
end

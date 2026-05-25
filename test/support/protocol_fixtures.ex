defmodule QuackDB.ProtocolFixtures do
  @moduledoc false

  import Bitwise

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Writer

  def prepare_response(options) do
    chunks = Keyword.get(options, :chunks, [])
    names = Keyword.get(options, :names, ["n"])
    needs_more_fetch? = Keyword.get(options, :needs_more_fetch?, false)
    result_uuid = Keyword.get(options, :result_uuid, 42)

    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :prepare_response, connection_id: "conn-1"}),
      Writer.field(1, Writer.list([integer_type()], &Function.identity/1)),
      Writer.field(2, Writer.list(names, &Writer.string/1)),
      Writer.field(3, Writer.bool(needs_more_fetch?)),
      Writer.field(4, Writer.list(chunks, &Writer.nullable(&1, fn chunk -> chunk end))),
      Writer.field(5, Writer.hugeint(result_uuid)),
      Writer.end_object()
    ])
  end

  def fetch_response(chunks, options \\ []) do
    batch_index = Keyword.get(options, :batch_index, nil)

    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :fetch_response, connection_id: "conn-1"}),
      Writer.field(1, Writer.list(chunks, &Writer.nullable(&1, fn chunk -> chunk end))),
      Writer.field(2, Writer.optional_index(batch_index)),
      Writer.end_object()
    ])
  end

  def error_response(message) do
    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :error_response, connection_id: "conn-1"}),
      Writer.field(1, Writer.string(message)),
      Writer.end_object()
    ])
  end

  def scalar_chunk_wrapper(columns) do
    row_count =
      columns
      |> List.first()
      |> elem(2)
      |> length()

    types = Enum.map(columns, fn {type, _physical_type, _values} -> logical_type(type) end)

    vectors =
      Enum.map(columns, fn {type, physical_type, values} ->
        vector(type, physical_type, values)
      end)

    [
      Writer.field(300, data_chunk(row_count, types, vectors)),
      Writer.end_object()
    ]
  end

  def integer_type do
    logical_type(:integer)
  end

  def logical_type(:decimal) do
    [
      Writer.field(100, Writer.uleb128(LogicalType.id(:decimal))),
      Writer.field(101, Writer.nullable(decimal_type_info(18, 2), &Function.identity/1)),
      Writer.end_object()
    ]
  end

  def logical_type(type) do
    [Writer.field(100, Writer.uleb128(LogicalType.id(type))), Writer.end_object()]
  end

  def integer_chunk_wrapper(values) do
    [Writer.field(300, integer_chunk(values)), Writer.end_object()]
  end

  def integer_chunk(values) do
    data_chunk(length(values), [integer_type()], [integer_vector(values)])
  end

  def data_chunk(row_count, types, vectors) do
    [
      Writer.field(100, Writer.uleb128(row_count)),
      Writer.field(101, Writer.list(types, &Function.identity/1)),
      Writer.field(102, Writer.list(vectors, &Function.identity/1)),
      Writer.end_object()
    ]
  end

  def vector(_type, :bool, values),
    do: fixed_vector(values, 1, fn value -> <<if(value, do: 1, else: 0)>> end)

  def vector(_type, :int32, values),
    do: fixed_vector(values, 4, fn value -> <<value::little-signed-32>> end)

  def vector(_type, :int64, values),
    do: fixed_vector(values, 8, fn value -> <<value::little-signed-64>> end)

  def vector(_type, :double, values),
    do: fixed_vector(values, 8, fn value -> <<value::little-float-64>> end)

  def vector(_type, :varchar, values), do: varchar_vector(values)

  def dictionary_integer_vector(selection, dictionary_values) do
    selection_payload = for index <- selection, into: <<>>, do: <<index::little-unsigned-32>>

    [
      Writer.field(90, Writer.uleb128(3)),
      Writer.field(91, Writer.blob(selection_payload)),
      Writer.field(92, Writer.uleb128(length(dictionary_values))),
      integer_vector(dictionary_values)
    ]
  end

  def sequence_integer_vector(start, increment) do
    [
      Writer.field(90, Writer.uleb128(4)),
      Writer.field(91, Writer.sleb128(start)),
      Writer.field(92, Writer.sleb128(increment)),
      Writer.end_object()
    ]
  end

  def integer_vector(values) do
    validity = Enum.map(values, &(!is_nil(&1)))
    payload = for value <- values, into: <<>>, do: <<value || 0::little-signed-32>>
    has_validity? = Enum.any?(validity, &(&1 == false))

    [
      Writer.field(100, Writer.bool(has_validity?)),
      maybe_validity_mask(validity, has_validity?),
      Writer.field(102, Writer.blob(payload)),
      Writer.end_object()
    ]
  end

  defp fixed_vector(values, byte_size, encode_value) do
    validity = Enum.map(values, &(!is_nil(&1)))
    payload = for value <- values, into: <<>>, do: encode_value.(default_value(value))
    has_validity? = Enum.any?(validity, &(&1 == false))

    [
      Writer.field(100, Writer.bool(has_validity?)),
      maybe_validity_mask(validity, has_validity?),
      Writer.field(102, Writer.blob(pad_payload(payload, byte_size, length(values)))),
      Writer.end_object()
    ]
  end

  defp varchar_vector(values) do
    validity = Enum.map(values, &(!is_nil(&1)))
    has_validity? = Enum.any?(validity, &(&1 == false))

    encoded_values =
      Enum.map(values, fn
        nil -> <<>>
        value when is_binary(value) -> value
      end)

    [
      Writer.field(100, Writer.bool(has_validity?)),
      maybe_validity_mask(validity, has_validity?),
      Writer.field(102, Writer.list(encoded_values, &Writer.blob/1)),
      Writer.end_object()
    ]
  end

  defp decimal_type_info(width, scale) do
    [
      Writer.field(100, Writer.uleb128(2)),
      Writer.field(200, Writer.uleb128(width)),
      Writer.field(201, Writer.uleb128(scale)),
      Writer.end_object()
    ]
  end

  defp default_value(nil), do: 0
  defp default_value(value), do: value

  defp pad_payload(payload, byte_size, count) when byte_size(payload) == byte_size * count,
    do: payload

  defp maybe_validity_mask(validity, true),
    do: Writer.field(101, Writer.blob(validity_mask(validity)))

  defp maybe_validity_mask(_validity, false), do: []

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

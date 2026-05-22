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

  def integer_type do
    [Writer.field(100, Writer.uleb128(LogicalType.id(:integer))), Writer.end_object()]
  end

  def integer_chunk_wrapper(values) do
    [Writer.field(300, integer_chunk(values)), Writer.end_object()]
  end

  def integer_chunk(values) do
    [
      Writer.field(100, Writer.uleb128(length(values))),
      Writer.field(101, Writer.list([integer_type()], &Function.identity/1)),
      Writer.field(102, Writer.list([integer_vector(values)], &Function.identity/1)),
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

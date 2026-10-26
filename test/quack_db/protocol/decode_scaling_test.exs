defmodule QuackDB.Protocol.DecodeScalingTest do
  # Guards against decoders that walk a list per lookup. Reductions count the
  # work a process does deterministically, so the ratio between decoding n and
  # 4n values is stable: linear decoders stay near 4, quadratic ones near 16.
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Variant
  alias QuackDB.Protocol.Vector
  alias QuackDB.Protocol.Writer

  @max_ratio 6

  test "dictionary vectors decode in linear time" do
    assert_linear(fn rows ->
      selection = for index <- 0..(rows - 1), into: <<>>, do: <<index::little-unsigned-32>>
      dictionary = Vector.encode(LogicalType.new(:integer), Enum.to_list(1..rows), rows)

      binary =
        IO.iodata_to_binary([
          Writer.field(90, Writer.uleb128(3)),
          Writer.field(91, Writer.blob(selection)),
          Writer.field(92, Writer.uleb128(rows)),
          dictionary
        ])

      fn -> {:ok, _vector, ""} = Vector.decode(binary, LogicalType.new(:integer), rows) end
    end)
  end

  test "ARRAY vectors decode in linear time" do
    assert_linear(fn rows ->
      {:ok, chunk} =
        DataChunk.from_columns([values: Enum.map(1..rows, &[&1, &1, &1, &1])],
          columns: [values: {:array, :integer, 4}]
        )

      binary = chunk |> DataChunk.encode() |> IO.iodata_to_binary()
      fn -> {:ok, _chunk, ""} = DataChunk.decode(binary) end
    end)
  end

  test "LIST vectors decode in linear time" do
    assert_linear(fn rows ->
      {:ok, chunk} =
        DataChunk.from_columns([values: Enum.map(1..rows, &[&1, &1])],
          columns: [values: {:list, :integer}]
        )

      binary = chunk |> DataChunk.encode() |> IO.iodata_to_binary()
      fn -> {:ok, _chunk, ""} = DataChunk.decode(binary) end
    end)
  end

  test "VARIANT arrays decode in linear time" do
    assert_linear(fn elements ->
      row = variant_array(elements)
      fn -> {:ok, [_value]} = Variant.decode_rows([row]) end
    end)
  end

  # A VARIANT row holding an array of `count` INTEGER values.
  defp variant_array(count) do
    header = IO.iodata_to_binary([Writer.uleb128(count), Writer.uleb128(0)])
    integers = for value <- 1..count, into: <<>>, do: <<value::little-signed-32>>

    %{
      "keys" => [],
      "children" => for(index <- 1..count, do: %{"keys_index" => nil, "values_index" => index}),
      "values" => [
        %{"type_id" => 30, "byte_offset" => 0}
        | for(
            index <- 0..(count - 1),
            do: %{"type_id" => 5, "byte_offset" => byte_size(header) + 4 * index}
          )
      ],
      "data" => header <> integers
    }
  end

  defp assert_linear(build) do
    small = reductions(build.(2_048))
    large = reductions(build.(8_192))
    ratio = large / small

    assert ratio < @max_ratio,
           "decoding 4x the values took #{Float.round(ratio, 1)}x the reductions"
  end

  defp reductions(decode) do
    decode.()
    {:reductions, before} = Process.info(self(), :reductions)
    decode.()
    {:reductions, after_decode} = Process.info(self(), :reductions)
    after_decode - before
  end
end

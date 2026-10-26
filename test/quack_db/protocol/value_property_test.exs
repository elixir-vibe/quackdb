defmodule QuackDB.Protocol.ValuePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Value

  # Value builds temporal structs from calendar fields instead of adding to
  # the epoch; these properties pin it to the standard library's arithmetic.

  # About ±3000 years around the epoch, in microseconds.
  @micros_range -94_670_000_000_000_000..94_670_000_000_000_000

  property "TIMESTAMP matches NaiveDateTime.add/3" do
    check all(micros <- integer(@micros_range)) do
      assert decode(:timestamp, :int64, micros) ==
               NaiveDateTime.add(~N[1970-01-01 00:00:00], micros, :microsecond)
    end
  end

  property "TIMESTAMP_S and TIMESTAMP_MS match NaiveDateTime.add/3" do
    check all(seconds <- integer(div(-94_670_000_000_000_000, 1_000_000)..94_670_000_000_000)) do
      assert decode(:timestamp_sec, :int64, seconds) ==
               NaiveDateTime.add(~N[1970-01-01 00:00:00], seconds, :second)

      assert decode(:timestamp_ms, :int64, seconds * 1000 + 7) ==
               NaiveDateTime.add(~N[1970-01-01 00:00:00], seconds * 1000 + 7, :millisecond)
    end
  end

  property "TIMESTAMPTZ matches DateTime.add/3" do
    check all(micros <- integer(@micros_range)) do
      assert decode(:timestamp_tz, :int64, micros) ==
               DateTime.add(~U[1970-01-01 00:00:00Z], micros, :microsecond)
    end
  end

  property "DATE matches Date.add/2" do
    check all(days <- integer(-1_100_000..1_100_000)) do
      assert decode(:date, :int32, days) == Date.add(~D[1970-01-01], days)
    end
  end

  property "TIME matches Time.add/3" do
    check all(micros <- integer(0..(86_400_000_000 - 1))) do
      assert decode(:time, :int64, micros) == Time.add(~T[00:00:00], micros, :microsecond)
    end
  end

  property "NULL rows skip conversion" do
    check all(values <- list_of(integer(-1_000_000..1_000_000), min_length: 1, max_length: 64)) do
      count = length(values)
      blob = for value <- values, into: <<>>, do: <<value::little-signed-32>>

      validity =
        for index <- 0..(div(count + 63, 64) * 64 - 1), into: <<>>, do: <<rem(index + 1, 2)::1>>

      validity = for <<byte::binary-size(1) <- validity>>, into: <<>>, do: reverse_bits(byte)

      assert {:ok, decoded} = Value.decode_column(blob, LogicalType.new(:date), :int32, validity)

      expected =
        values
        |> Enum.with_index()
        |> Enum.map(fn {days, index} ->
          if rem(index, 2) == 0, do: Date.add(~D[1970-01-01], days)
        end)

      assert decoded == expected
    end
  end

  test "ENUM indexes outside the labels fail without raising" do
    type = LogicalType.new(:enum, %{type: 6, values: ["a", "b"]})

    assert {:ok, ["b", "a"]} = Value.decode_column(<<1, 0>>, type, :uint8, nil)

    assert {:error, %QuackDB.Error{code: :enum_index_out_of_range}} =
             Value.decode_column(<<2>>, type, :uint8, nil)
  end

  defp decode(name, physical_type, value) do
    size = LogicalType.fixed_size(physical_type) * 8

    assert {:ok, decoded, ""} =
             Value.decode_fixed(
               <<value::little-signed-size(size)>>,
               LogicalType.new(name),
               physical_type
             )

    decoded
  end

  # Validity bitmasks are little-endian within each byte.
  defp reverse_bits(<<a::1, b::1, c::1, d::1, e::1, f::1, g::1, h::1>>),
    do: <<h::1, g::1, f::1, e::1, d::1, c::1, b::1, a::1>>
end

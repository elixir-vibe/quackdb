defmodule QuackDB.Protocol.Value do
  @moduledoc """
  Scalar value conversion for decoded DuckDB vectors.

  Converts fixed-width physical values into Elixir terms such as booleans,
  integers, floats, `Date`, `DateTime`, `Decimal`, and DuckDB-specific temporal
  and interval structs.
  """

  import Bitwise

  alias QuackDB.Error
  alias QuackDB.Protocol.Reader

  @spec decode_fixed(binary(), map(), atom()) :: Reader.read_result(term())
  def decode_fixed(binary, _type, :bool) do
    with {:ok, value, rest} <- Reader.read_uint8(binary), do: {:ok, value != 0, rest}
  end

  def decode_fixed(binary, _type, :int8), do: Reader.read_int8(binary)

  def decode_fixed(binary, %{name: :enum} = type, :uint8),
    do: decode_enum(binary, type, &Reader.read_uint8/1)

  def decode_fixed(binary, _type, :uint8), do: Reader.read_uint8(binary)

  def decode_fixed(binary, %{name: :decimal} = type, :int16) do
    with {:ok, value, rest} <- Reader.read_int16(binary), do: {:ok, decimal(type, value), rest}
  end

  def decode_fixed(binary, _type, :int16), do: Reader.read_int16(binary)

  def decode_fixed(binary, %{name: :enum} = type, :uint16),
    do: decode_enum(binary, type, &Reader.read_uint16/1)

  def decode_fixed(binary, _type, :uint16), do: Reader.read_uint16(binary)

  def decode_fixed(binary, %{name: :date}, :int32) do
    with {:ok, days, rest} <- Reader.read_int32(binary),
         do: {:ok, Date.add(~D[1970-01-01], days), rest}
  end

  def decode_fixed(binary, %{name: :decimal} = type, :int32) do
    with {:ok, value, rest} <- Reader.read_int32(binary), do: {:ok, decimal(type, value), rest}
  end

  def decode_fixed(binary, _type, :int32), do: Reader.read_int32(binary)

  def decode_fixed(binary, %{name: :enum} = type, :uint32),
    do: decode_enum(binary, type, &Reader.read_uint32/1)

  def decode_fixed(binary, _type, :uint32), do: Reader.read_uint32(binary)

  def decode_fixed(binary, %{name: name}, :int64)
      when name in [
             :time,
             :time_ns,
             :timestamp_sec,
             :timestamp_ms,
             :timestamp,
             :timestamp_ns,
             :time_tz,
             :timestamp_tz
           ] do
    with {:ok, value, rest} <- Reader.read_int64(binary), do: {:ok, temporal(name, value), rest}
  end

  def decode_fixed(binary, %{name: :decimal} = type, :int64) do
    with {:ok, value, rest} <- Reader.read_int64(binary), do: {:ok, decimal(type, value), rest}
  end

  def decode_fixed(binary, _type, :int64), do: Reader.read_int64(binary)
  def decode_fixed(binary, _type, :uint64), do: Reader.read_uint64(binary)
  def decode_fixed(binary, _type, :float), do: Reader.read_float32(binary)
  def decode_fixed(binary, _type, :double), do: Reader.read_float64(binary)

  def decode_fixed(binary, %{name: :decimal} = type, :int128) do
    with {:ok, value, rest} <- read_int128(binary), do: {:ok, decimal(type, value), rest}
  end

  def decode_fixed(binary, %{name: :uuid}, :int128), do: read_uuid(binary)

  def decode_fixed(binary, _type, :int128), do: read_int128(binary)

  def decode_fixed(binary, _type, :uint128) do
    with {:ok, lower, rest} <- Reader.read_uint64(binary),
         {:ok, upper, rest} <- Reader.read_uint64(rest) do
      {:ok, upper * (1 <<< 64) + lower, rest}
    end
  end

  def decode_fixed(binary, _type, :interval) do
    with {:ok, months, rest} <- Reader.read_int32(binary),
         {:ok, days, rest} <- Reader.read_int32(rest),
         {:ok, micros, rest} <- Reader.read_int64(rest) do
      {:ok, QuackDB.Interval.new(months, days, micros), rest}
    end
  end

  @spec decode_sequence(map(), integer()) :: term()
  def decode_sequence(%{name: :integer}, value), do: value
  def decode_sequence(%{name: :date}, value), do: Date.add(~D[1970-01-01], value)

  def decode_sequence(%{name: type}, value)
      when type in [
             :time,
             :time_ns,
             :timestamp_sec,
             :timestamp_ms,
             :timestamp,
             :timestamp_ns,
             :time_tz,
             :timestamp_tz
           ],
      do: temporal(type, value)

  def decode_sequence(_type, value), do: value

  defp read_int128(binary) do
    with {:ok, lower, rest} <- Reader.read_uint64(binary),
         {:ok, upper, rest} <- Reader.read_int64(rest) do
      {:ok, upper * (1 <<< 64) + lower, rest}
    end
  end

  defp read_uuid(binary) do
    with {:ok, lower, rest} <- Reader.read_uint64(binary),
         {:ok, upper, rest} <- Reader.read_int64(rest) do
      display_upper = Bitwise.bxor(upper &&& 0xFFFF_FFFF_FFFF_FFFF, 1 <<< 63)

      hex =
        String.pad_leading(Integer.to_string(display_upper, 16), 16, "0") <>
          String.pad_leading(Integer.to_string(lower, 16), 16, "0")

      uuid =
        hex
        |> String.downcase()
        |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
                     e::binary>> ->
          Enum.join([a, b, c, d, e], "-")
        end)

      {:ok, uuid, rest}
    end
  end

  defp decode_enum(binary, %{type_info: %{values: values}}, read_index) do
    with {:ok, index, rest} <- read_index.(binary) do
      case Enum.fetch(values, index) do
        {:ok, value} ->
          {:ok, value, rest}

        :error ->
          {:error,
           Error.new(:enum_index_out_of_range, "ENUM index #{index} is out of range",
             source: :protocol
           )}
      end
    end
  end

  defp decimal(%{type_info: %{scale: scale}}, value) do
    sign = if value < 0, do: -1, else: 1
    Decimal.new(sign, abs(value), -scale)
  end

  defp temporal(:time, value), do: Time.add(~T[00:00:00], value, :microsecond)

  defp temporal(:timestamp_sec, value),
    do: NaiveDateTime.add(~N[1970-01-01 00:00:00], value, :second)

  defp temporal(:timestamp_ms, value),
    do: NaiveDateTime.add(~N[1970-01-01 00:00:00], value, :millisecond)

  defp temporal(:timestamp, value),
    do: NaiveDateTime.add(~N[1970-01-01 00:00:00], value, :microsecond)

  defp temporal(:timestamp_tz, value),
    do: DateTime.add(~U[1970-01-01 00:00:00Z], value, :microsecond)

  defp temporal(:time_ns, value), do: QuackDB.NanosecondTime.new(value)
  defp temporal(:time_tz, value), do: QuackDB.TimeWithTimeZone.from_bits(value)
  defp temporal(:timestamp_ns, value), do: QuackDB.NanosecondTimestamp.new(value)
end

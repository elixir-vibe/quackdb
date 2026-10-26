defmodule QuackDB.Protocol.Value do
  @moduledoc """
  Scalar value normalization for DuckDB logical types.

  Fixed-width vectors decode in two steps: one binary comprehension per
  physical type reads the raw integers or floats, and a converter chosen once
  per vector turns them into Elixir values for the logical type, such as
  `Date`, `Decimal`, or ENUM labels. NULL rows skip conversion.
  """

  import Bitwise
  import QuackDB.Protocol.LogicalType, only: [is_int64_temporal: 1]

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader

  @unix_epoch_days 719_528
  @unconverted [
    :boolean,
    :tinyint,
    :smallint,
    :integer,
    :bigint,
    :hugeint,
    :utinyint,
    :usmallint,
    :uinteger,
    :ubigint,
    :uhugeint,
    :float,
    :double,
    :interval
  ]
  @microseconds_per_day 86_400_000_000

  @doc """
  Decodes a fixed-width vector blob. `validity` is the vector's validity
  bitmask, or `nil` when every row is valid.
  """
  @spec decode_column(binary(), LogicalType.t(), atom(), binary() | nil) ::
          {:ok, [term()]} | {:error, Error.t()}
  def decode_column(blob, type, physical_type, validity) do
    blob
    |> raw_values(physical_type)
    |> convert_column(converter(type, physical_type), validity)
  catch
    {:invalid_value, %Error{} = error} -> {:error, error}
  end

  @doc """
  Decodes one fixed-width value from the front of `binary`.
  """
  @spec decode_fixed(binary(), LogicalType.t(), atom()) :: Reader.read_result(term())
  def decode_fixed(binary, type, physical_type) do
    with {:ok, raw, rest} <- read_raw(binary, physical_type) do
      case converter(type, physical_type) do
        nil -> {:ok, raw, rest}
        convert -> {:ok, convert.(raw), rest}
      end
    end
  catch
    {:invalid_value, %Error{} = error} -> {:error, error}
  end

  # One raw value, for callers that decode values one at a time.
  defp read_raw(binary, :bool) do
    with {:ok, byte, rest} <- Reader.read_uint8(binary), do: {:ok, byte != 0, rest}
  end

  defp read_raw(binary, :int8), do: Reader.read_int8(binary)
  defp read_raw(binary, :uint8), do: Reader.read_uint8(binary)
  defp read_raw(binary, :int16), do: Reader.read_int16(binary)
  defp read_raw(binary, :uint16), do: Reader.read_uint16(binary)
  defp read_raw(binary, :int32), do: Reader.read_int32(binary)
  defp read_raw(binary, :uint32), do: Reader.read_uint32(binary)
  defp read_raw(binary, :int64), do: Reader.read_int64(binary)
  defp read_raw(binary, :uint64), do: Reader.read_uint64(binary)
  defp read_raw(binary, :float), do: Reader.read_float32(binary)
  defp read_raw(binary, :double), do: Reader.read_float64(binary)

  defp read_raw(binary, physical_type) when physical_type in [:int128, :uint128, :interval] do
    case binary do
      <<value::binary-size(16), rest::binary>> ->
        [raw] = raw_values(value, physical_type)
        {:ok, raw, rest}

      _short ->
        {:error,
         Error.new(:truncated_value, "expected a 16-byte #{physical_type} value",
           source: :protocol
         )}
    end
  end

  @doc """
  Converts a value of a sequence vector, which DuckDB stores as integers.
  """
  @spec decode_sequence(LogicalType.t(), integer()) :: term()
  def decode_sequence(type, value) do
    case converter(type, LogicalType.physical_type(type)) do
      nil -> value
      convert -> convert.(value)
    end
  end

  defp raw_values(blob, :bool), do: for(<<byte <- blob>>, do: byte != 0)
  defp raw_values(blob, :int8), do: for(<<value::signed-8 <- blob>>, do: value)
  defp raw_values(blob, :uint8), do: for(<<value::unsigned-8 <- blob>>, do: value)
  defp raw_values(blob, :int16), do: for(<<value::little-signed-16 <- blob>>, do: value)
  defp raw_values(blob, :uint16), do: for(<<value::little-unsigned-16 <- blob>>, do: value)
  defp raw_values(blob, :int32), do: for(<<value::little-signed-32 <- blob>>, do: value)
  defp raw_values(blob, :uint32), do: for(<<value::little-unsigned-32 <- blob>>, do: value)
  defp raw_values(blob, :int64), do: for(<<value::little-signed-64 <- blob>>, do: value)
  defp raw_values(blob, :uint64), do: for(<<value::little-unsigned-64 <- blob>>, do: value)

  # Floats are taken as bytes first: a float segment does not match the
  # non-finite bit patterns, which Reader.read_float*/1 map to atoms.
  defp raw_values(blob, :float), do: for(<<value::binary-size(4) <- blob>>, do: float32(value))
  defp raw_values(blob, :double), do: for(<<value::binary-size(8) <- blob>>, do: float64(value))

  defp raw_values(blob, :int128) do
    for <<lower::little-unsigned-64, upper::little-signed-64 <- blob>>,
      do: (upper <<< 64) + lower
  end

  defp raw_values(blob, :uint128) do
    for <<lower::little-unsigned-64, upper::little-unsigned-64 <- blob>>,
      do: (upper <<< 64) + lower
  end

  defp raw_values(blob, :interval) do
    for <<months::little-signed-32, days::little-signed-32, micros::little-signed-64 <- blob>>,
      do: QuackDB.Interval.new(months, days, micros)
  end

  defp float32(<<value::little-float-32>>), do: value
  defp float32(bytes), do: bytes |> Reader.read_float32() |> elem(1)

  defp float64(<<value::little-float-64>>), do: value
  defp float64(bytes), do: bytes |> Reader.read_float64() |> elem(1)

  defp convert_column(values, nil, nil), do: {:ok, values}
  defp convert_column(values, convert, nil), do: {:ok, Enum.map(values, convert)}

  defp convert_column(values, convert, validity),
    do: {:ok, convert_valid(values, convert, validity, 0, [])}

  defp convert_valid([], _convert, _validity, _index, converted), do: Enum.reverse(converted)

  defp convert_valid([value | values], convert, validity, index, converted) do
    value =
      cond do
        not valid?(validity, index) -> nil
        convert -> convert.(value)
        true -> value
      end

    convert_valid(values, convert, validity, index + 1, [value | converted])
  end

  defp valid?(validity, index) do
    (:binary.at(validity, index >>> 3) &&& 1 <<< (index &&& 7)) != 0
  end

  # Returns the function that turns a raw value into the logical type's
  # Elixir value, or nil when the raw value already is that value.
  defp converter(%{name: name}, _physical_type) when name in @unconverted, do: nil

  defp converter(%{name: :decimal, type_info: %{scale: scale}}, _physical_type),
    do: &decimal(&1, scale)

  defp converter(%{name: :date}, _physical_type),
    do: &Date.from_gregorian_days(&1 + @unix_epoch_days)

  defp converter(%{name: name}, _physical_type) when is_int64_temporal(name),
    do: &temporal(name, &1)

  defp converter(%{name: :uuid}, _physical_type), do: &uuid/1

  defp converter(%{name: :enum, type_info: %{values: labels}}, _physical_type) do
    labels = List.to_tuple(labels)
    &enum_label(labels, &1)
  end

  defp converter(_type, _physical_type), do: nil

  defp decimal(value, scale) when value < 0, do: Decimal.new(-1, -value, -scale)
  defp decimal(value, scale), do: Decimal.new(1, value, -scale)

  defp enum_label(labels, index) when index < tuple_size(labels), do: elem(labels, index)

  defp enum_label(_labels, index) do
    throw(
      {:invalid_value,
       Error.new(:enum_index_out_of_range, "ENUM index #{index} is out of range",
         source: :protocol
       )}
    )
  end

  # DuckDB stores UUIDs as int128 with the top bit flipped, so they sort
  # like their canonical strings.
  defp uuid(value) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> =
      (value + (1 <<< 127))
      |> band((1 <<< 128) - 1)
      |> Integer.to_string(16)
      |> String.pad_leading(32, "0")
      |> String.downcase()

    <<a::binary, ?-, b::binary, ?-, c::binary, ?-, d::binary, ?-, e::binary>>
  end

  defp temporal(:time, micros), do: time(micros)
  defp temporal(:timestamp_sec, seconds), do: naive_datetime(seconds * 1_000_000, 0)
  defp temporal(:timestamp_ms, millis), do: naive_datetime(millis * 1_000, 3)
  defp temporal(:timestamp, micros), do: naive_datetime(micros, 6)

  defp temporal(:timestamp_tz, micros) do
    naive = naive_datetime(micros, 6)

    %DateTime{
      year: naive.year,
      month: naive.month,
      day: naive.day,
      hour: naive.hour,
      minute: naive.minute,
      second: naive.second,
      microsecond: naive.microsecond,
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0,
      calendar: Calendar.ISO
    }
  end

  defp temporal(:time_ns, value), do: QuackDB.NanosecondTime.new(value)
  defp temporal(:time_tz, value), do: QuackDB.TimeWithTimeZone.from_bits(value)
  defp temporal(:timestamp_ns, value), do: QuackDB.NanosecondTimestamp.new(value)
  # The UTC instant; Elixir has no nanosecond DateTime.
  defp temporal(:timestamp_tz_ns, value), do: QuackDB.NanosecondTimestamp.new(value)

  defp time(micros) do
    Time.from_seconds_after_midnight(div(micros, 1_000_000), {rem(micros, 1_000_000), 6})
  end

  # Builds the struct from calendar fields; this is about twice as fast as
  # NaiveDateTime.add/3 from the epoch.
  defp naive_datetime(micros, precision) do
    days = Integer.floor_div(micros, @microseconds_per_day)
    micros_of_day = micros - days * @microseconds_per_day
    seconds = div(micros_of_day, 1_000_000)
    {year, month, day} = Calendar.ISO.date_from_iso_days(days + @unix_epoch_days)

    %NaiveDateTime{
      year: year,
      month: month,
      day: day,
      hour: div(seconds, 3600),
      minute: rem(div(seconds, 60), 60),
      second: rem(seconds, 60),
      microsecond: {rem(micros_of_day, 1_000_000), precision},
      calendar: Calendar.ISO
    }
  end
end

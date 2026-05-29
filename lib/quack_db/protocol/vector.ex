defmodule QuackDB.Protocol.Vector do
  @moduledoc """
  DuckDB vector encoding and decoding helpers.
  """

  import Bitwise

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Value
  alias QuackDB.Protocol.Writer

  @type t :: %{type: LogicalType.t(), vector_type: atom(), values: [term()]}

  @spec encode(LogicalType.t(), [term()], non_neg_integer()) :: iodata()
  def encode(type, values, row_count) when is_list(values) do
    if Enum.count(values) == row_count do
      [encode_flat(type, values, row_count), Writer.end_object()]
    else
      raise Error.new(
              :invalid_vector_size,
              "vector has #{Enum.count(values)} values, expected #{row_count}",
              source: :protocol
            )
    end
  end

  @spec decode(binary(), LogicalType.t(), non_neg_integer()) :: Reader.read_result(t())
  def decode(binary, type, row_count) do
    decode_object(binary, type, row_count, %{type: type, vector_type: :flat, values: []})
  end

  defp encode_flat(type, values, row_count) do
    validity = Enum.map(values, &(!is_nil(&1)))
    has_validity? = Enum.any?(validity, &(!&1))

    [
      maybe_geometry_version(type),
      Writer.field(100, Writer.bool(has_validity?)),
      maybe_validity_mask(validity, has_validity?),
      encode_values(type, values, row_count)
    ]
  end

  defp maybe_geometry_version(%LogicalType{name: :geometry}),
    do: Writer.field(99, Writer.uleb128(1))

  defp maybe_geometry_version(_type), do: []

  defp maybe_validity_mask(validity, true),
    do: Writer.field(101, Writer.blob(validity_mask(validity)))

  defp maybe_validity_mask(_validity, false), do: []

  defp encode_values(type, values, row_count) do
    physical_type = LogicalType.physical_type(type)

    if LogicalType.fixed_size?(physical_type) do
      blob =
        values |> Enum.map(&encode_fixed_value(type, physical_type, &1)) |> IO.iodata_to_binary()

      expected_size = LogicalType.fixed_size(physical_type) * row_count

      if byte_size(blob) == expected_size do
        Writer.field(102, Writer.blob(blob))
      else
        raise Error.new(
                :invalid_vector_size,
                "encoded vector has #{byte_size(blob)} bytes, expected #{expected_size}",
                source: :protocol
              )
      end
    else
      encode_variable_values(type, values, physical_type)
    end
  end

  defp encode_variable_values(type, values, :varchar) do
    Writer.field(
      102,
      Writer.list(values, fn value -> Writer.blob(encode_string_like(type, value)) end)
    )
  end

  defp encode_variable_values(type, values, :struct) do
    children = LogicalType.struct_children(type)

    Writer.field(
      103,
      Writer.list(children, fn child ->
        child_values = Enum.map(values, &struct_child_value(&1, child.name))
        encode(child.type, child_values, length(child_values))
      end)
    )
  end

  defp encode_variable_values(%LogicalType{name: :map} = type, values, :list) do
    child_type = LogicalType.child_type(type)

    values =
      Enum.map(values, fn
        nil -> nil
        value when is_map(value) -> map_to_entries(value)
        value -> value
      end)

    {entries, child_values, _offset} = Enum.reduce(values, {[], [], 0}, &append_list_entry/2)

    [
      Writer.field(104, Writer.uleb128(length(child_values))),
      Writer.field(105, Writer.list(Enum.reverse(entries), &encode_list_entry/1)),
      Writer.field(106, encode(child_type, child_values, length(child_values)))
    ]
  end

  defp encode_variable_values(type, values, :list) do
    child_type = LogicalType.child_type(type)
    {entries, child_values, _offset} = Enum.reduce(values, {[], [], 0}, &append_list_entry/2)

    [
      Writer.field(104, Writer.uleb128(length(child_values))),
      Writer.field(105, Writer.list(Enum.reverse(entries), &encode_list_entry/1)),
      Writer.field(106, encode(child_type, child_values, length(child_values)))
    ]
  end

  defp encode_variable_values(type, values, :array) do
    child_type = LogicalType.child_type(type)
    array_size = LogicalType.array_size(type)

    child_values =
      Enum.flat_map(values, fn
        nil ->
          List.duplicate(nil, array_size)

        value when is_list(value) ->
          if Enum.count(value) == array_size do
            value
          else
            invalid_array_value!(value, array_size)
          end

        value ->
          invalid_array_value!(value, array_size)
      end)

    [
      Writer.field(103, Writer.uleb128(array_size)),
      Writer.field(104, encode(child_type, child_values, length(child_values)))
    ]
  end

  defp encode_variable_values(_type, _values, physical_type) do
    raise Error.new(:unsupported_physical_type, "#{physical_type} vectors are not encodable yet",
            source: :protocol
          )
  end

  defp map_to_entries(value) do
    Enum.map(value, fn {key, entry_value} -> %{key: key, value: entry_value} end)
  end

  defp invalid_array_value!(value, array_size) do
    raise Error.new(
            :invalid_array_value,
            "ARRAY values must be lists of #{array_size} elements, got #{inspect(value)}",
            source: :protocol
          )
  end

  defp decode_object(binary, type, row_count, vector) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, vector, rest}

        field_id == 90 ->
          with {:ok, vector_type_id, rest} <- Reader.read_uleb128(rest),
               {:ok, vector_type} <- vector_type(vector_type_id) do
            decode_object(rest, type, row_count, %{vector | vector_type: vector_type})
          end

        true ->
          decode_body(binary, type, row_count, vector.vector_type)
      end
    end
  end

  defp decode_body(binary, type, row_count, :flat) do
    decode_flat(binary, type, row_count, %{type: type, vector_type: :flat, values: []})
  end

  defp decode_body(binary, type, row_count, :constant) do
    with {:ok, vector, rest} <- decode_body(binary, type, min(row_count, 1), :flat) do
      value = List.first(vector.values)
      {:ok, %{vector | vector_type: :constant, values: List.duplicate(value, row_count)}, rest}
    end
  end

  defp decode_body(binary, type, row_count, :dictionary) do
    with {:ok, selection, rest} <- read_required(binary, 91, &read_selection(&1, row_count)),
         {:ok, dictionary_count, rest} <- read_required(rest, 92, &Reader.read_uleb128/1),
         {:ok, dictionary, rest} <-
           decode_object(rest, type, dictionary_count, %{
             type: type,
             vector_type: :flat,
             values: []
           }),
         {:ok, values} <- select_dictionary_values(dictionary.values, selection) do
      {:ok, %{type: type, vector_type: :dictionary, values: values}, rest}
    end
  end

  defp decode_body(binary, type, row_count, :sequence) do
    with {:ok, start, rest} <- read_required(binary, 91, &Reader.read_sleb128/1),
         {:ok, increment, rest} <- read_required(rest, 92, &Reader.read_sleb128/1),
         {:ok, field_end, rest} <- Reader.read_field_id(rest),
         :ok <- expect_vector_end(field_end) do
      values =
        for index <- 0..(row_count - 1)//1,
            do: Value.decode_sequence(type, start + increment * index)

      {:ok, %{type: type, vector_type: :sequence, values: values}, rest}
    end
  end

  defp decode_body(_binary, _type, _row_count, vector_type) do
    error(:unsupported_vector_type, "#{vector_type} vectors are not implemented yet")
  end

  defp decode_flat(binary, type, row_count, vector) do
    with {:ok, rest} <- maybe_skip_geometry_version(binary, type),
         {:ok, has_validity?, rest} <- read_required(rest, 100, &Reader.read_bool/1),
         {:ok, validity, rest} <- maybe_read_validity(rest, has_validity?, row_count),
         {:ok, values, rest} <- read_values(rest, type, row_count, validity),
         {:ok, field_end, rest} <- Reader.read_field_id(rest),
         :ok <- expect_vector_end(field_end) do
      {:ok, %{vector | values: values}, rest}
    end
  end

  defp maybe_skip_geometry_version(binary, %{name: :geometry}) do
    case Reader.read_field_id(binary) do
      {:ok, 99, rest} ->
        with {:ok, _version, rest} <- Reader.read_uleb128(rest), do: {:ok, rest}

      {:ok, _field_id, _rest} ->
        {:ok, binary}

      {:error, _error} = error ->
        error
    end
  end

  defp maybe_skip_geometry_version(binary, _type), do: {:ok, binary}

  defp read_values(binary, type, row_count, validity) do
    physical_type = LogicalType.physical_type(type)

    if LogicalType.fixed_size?(physical_type) do
      byte_size = LogicalType.fixed_size(physical_type) * row_count

      with {:ok, blob, rest} <- read_required(binary, 102, &Reader.read_blob/1),
           :ok <- expect_blob_size(blob, byte_size),
           {:ok, values} <- decode_fixed_values(blob, type, physical_type, row_count, validity) do
        {:ok, values, rest}
      end
    else
      decode_variable_values(binary, type, physical_type, row_count, validity)
    end
  end

  defp decode_variable_values(binary, type, :varchar, row_count, validity) do
    read_blob_list = fn rest -> Reader.read_list(rest, &Reader.read_blob/1) end

    with {:ok, values, rest} <- read_required(binary, 102, read_blob_list),
         :ok <- expect_value_count(values, row_count, :varchar) do
      values =
        values
        |> Enum.with_index()
        |> Enum.map(fn {value, index} ->
          if valid?(validity, index), do: decode_string_like(type, value), else: nil
        end)

      {:ok, values, rest}
    end
  end

  defp decode_variable_values(binary, type, :struct, row_count, validity) do
    children = LogicalType.struct_children(type)

    with {:ok, child_vectors, rest} <-
           read_required(binary, 103, &read_child_vectors(&1, children, row_count)) do
      values =
        for row_index <- 0..(row_count - 1)//1 do
          if valid?(validity, row_index) do
            children
            |> Enum.zip(child_vectors)
            |> Map.new(fn {%{name: name}, vector} ->
              {name, Enum.at(vector.values, row_index)}
            end)
          else
            nil
          end
        end

      {:ok, values, rest}
    end
  end

  defp decode_variable_values(binary, type, :list, row_count, validity) do
    with {:ok, list_size, rest} <- read_required(binary, 104, &Reader.read_uleb128/1),
         {:ok, entries, rest} <- read_required(rest, 105, &read_list_entries(&1, row_count)),
         {:ok, child_vector, rest} <-
           read_required(rest, 106, &decode(&1, LogicalType.child_type(type), list_size)) do
      with :ok <- validate_list_entries(entries, list_size),
           {:ok, values} <- list_values(type, entries, child_vector.values, validity) do
        {:ok, values, rest}
      end
    end
  end

  defp decode_variable_values(binary, type, :array, row_count, validity) do
    with {:ok, array_size, rest} <- read_required(binary, 103, &Reader.read_uleb128/1),
         :ok <- expect_array_size(type, array_size),
         {:ok, child_vector, rest} <-
           read_required(
             rest,
             104,
             &decode(&1, LogicalType.child_type(type), array_size * row_count)
           ) do
      values =
        for row_index <- 0..(row_count - 1)//1 do
          if valid?(validity, row_index) do
            Enum.slice(child_vector.values, row_index * array_size, array_size)
          else
            nil
          end
        end

      {:ok, values, rest}
    end
  end

  defp decode_variable_values(_binary, _type, physical_type, _row_count, _validity) do
    error(:unsupported_physical_type, "#{physical_type} vectors are not implemented yet")
  end

  defp encode_fixed_value(_type, physical_type, nil) do
    :binary.copy(<<0>>, LogicalType.fixed_size(physical_type))
  end

  defp encode_fixed_value(_type, :bool, value), do: <<if(value, do: 1, else: 0)>>
  defp encode_fixed_value(_type, :int8, value), do: <<value::little-signed-8>>
  defp encode_fixed_value(_type, :uint8, value), do: <<value::little-unsigned-8>>
  defp encode_fixed_value(_type, :int16, value), do: <<value::little-signed-16>>
  defp encode_fixed_value(_type, :uint16, value), do: <<value::little-unsigned-16>>

  defp encode_fixed_value(
         %LogicalType{name: :date},
         :int32,
         %{calendar: _, year: _, month: _, day: _} = value
       ),
       do: <<date_unscaled(value)::little-signed-32>>

  defp encode_fixed_value(%LogicalType{name: :decimal} = type, :int32, value),
    do: <<decimal_unscaled(type, value)::little-signed-32>>

  defp encode_fixed_value(_type, :int32, value), do: <<value::little-signed-32>>
  defp encode_fixed_value(_type, :uint32, value), do: <<value::little-unsigned-32>>

  defp encode_fixed_value(%LogicalType{name: :decimal} = type, :int64, value),
    do: <<decimal_unscaled(type, value)::little-signed-64>>

  defp encode_fixed_value(%LogicalType{name: name}, :int64, value)
       when name in [
              :time,
              :time_ns,
              :time_tz,
              :timestamp,
              :timestamp_ms,
              :timestamp_ns,
              :timestamp_sec,
              :timestamp_tz
            ],
       do: <<temporal_unscaled(name, value)::little-signed-64>>

  defp encode_fixed_value(_type, :int64, value), do: <<value::little-signed-64>>
  defp encode_fixed_value(_type, :uint64, value), do: <<value::little-unsigned-64>>
  defp encode_fixed_value(_type, :float, value), do: <<value::little-float-32>>
  defp encode_fixed_value(_type, :double, value), do: <<value::little-float-64>>

  defp encode_fixed_value(%LogicalType{name: :decimal} = type, :int128, value),
    do: encode_int128(decimal_unscaled(type, value))

  defp encode_fixed_value(_type, :int128, value), do: encode_int128(value)
  defp encode_fixed_value(_type, :uint128, value), do: encode_uint128(value)

  defp encode_fixed_value(_type, :interval, %QuackDB.Interval{} = interval),
    do: encode_interval(interval.months, interval.days, interval.microseconds)

  defp encode_fixed_value(_type, :interval, {:interval, months, days, micros}),
    do: encode_interval(months, days, micros)

  defp decimal_unscaled(%LogicalType{type_info: %{scale: scale}}, %Decimal{} = decimal) do
    decimal
    |> Decimal.mult(Decimal.new(1, 1, scale))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp decimal_unscaled(_type, value), do: value

  defp encode_interval(months, days, micros) do
    <<months::little-signed-32, days::little-signed-32, micros::little-signed-64>>
  end

  defp date_unscaled(value) do
    value
    |> convert_date!()
    |> Date.diff(~D[1970-01-01])
  end

  defp temporal_unscaled(
         :time,
         %{calendar: _, hour: _, minute: _, second: _, microsecond: _} = value
       ) do
    value
    |> convert_time!()
    |> Time.diff(~T[00:00:00], :microsecond)
  end

  defp temporal_unscaled(:timestamp, value), do: timestamp_unscaled(value, :microsecond)

  defp temporal_unscaled(:timestamp_tz, %DateTime{} = value) do
    value
    |> convert_datetime!()
    |> DateTime.diff(~U[1970-01-01 00:00:00Z], :microsecond)
  end

  defp temporal_unscaled(:timestamp_ms, value), do: timestamp_unscaled(value, :millisecond)
  defp temporal_unscaled(:timestamp_sec, value), do: timestamp_unscaled(value, :second)

  defp temporal_unscaled(:time_ns, %QuackDB.NanosecondTime{nanoseconds: nanoseconds}),
    do: nanoseconds

  defp temporal_unscaled(:time_tz, %QuackDB.TimeWithTimeZone{} = value),
    do: QuackDB.TimeWithTimeZone.to_bits(value)

  defp temporal_unscaled(:timestamp_ns, %QuackDB.NanosecondTimestamp{nanoseconds: nanoseconds}),
    do: nanoseconds

  defp temporal_unscaled(_type, value) when is_integer(value), do: value

  defp timestamp_unscaled(
         %{calendar: _, year: _, month: _, day: _, hour: _, minute: _, second: _, microsecond: _} =
           value,
         unit
       ) do
    value
    |> convert_naive_datetime!()
    |> NaiveDateTime.diff(~N[1970-01-01 00:00:00], unit)
  end

  defp convert_date!(value), do: convert_calendar!(Date, value, :date)
  defp convert_time!(value), do: convert_calendar!(Time, value, :time)
  defp convert_naive_datetime!(value), do: convert_calendar!(NaiveDateTime, value, :timestamp)
  defp convert_datetime!(value), do: convert_calendar!(DateTime, value, :timestamp_tz)

  defp convert_calendar!(module, value, target) do
    case module.convert(value, Calendar.ISO) do
      {:ok, converted} ->
        converted

      {:error, reason} ->
        raise Error.new(
                :unsupported_calendar,
                "cannot encode #{inspect(value)} as DuckDB #{target}: #{inspect(reason)}",
                source: :protocol
              )
    end
  end

  defp encode_int128(value) do
    lower = value &&& 0xFFFF_FFFF_FFFF_FFFF
    upper = value >>> 64
    <<lower::little-unsigned-64, upper::little-signed-64>>
  end

  defp encode_uint128(value) do
    lower = value &&& 0xFFFF_FFFF_FFFF_FFFF
    upper = value >>> 64
    <<lower::little-unsigned-64, upper::little-unsigned-64>>
  end

  defp encode_string_like(_type, nil), do: ""

  defp encode_string_like(%LogicalType{name: name}, value)
       when name in [:blob, :bit, :geometry] and is_binary(value),
       do: value

  defp encode_string_like(%LogicalType{name: :bignum}, value) when is_integer(value),
    do: encode_bignum(value)

  defp encode_string_like(_type, value), do: to_string(value)

  defp validity_mask(validity) do
    bytes = div(length(validity) + 63, 64) * 8

    validity
    |> Enum.with_index()
    |> Enum.reduce(:binary.copy(<<0>>, bytes), fn
      {true, index}, mask -> set_mask_bit(mask, index)
      {false, _index}, mask -> mask
    end)
  end

  defp set_mask_bit(mask, index) do
    byte_index = div(index, 8)
    bit = 1 <<< rem(index, 8)
    <<prefix::binary-size(byte_index), byte, suffix::binary>> = mask
    <<prefix::binary, byte ||| bit, suffix::binary>>
  end

  defp append_list_entry(nil, {entries, child_values, offset}) do
    {[%{offset: 0, length: 0} | entries], child_values, offset}
  end

  defp append_list_entry(value, {entries, child_values, offset}) when is_list(value) do
    {[%{offset: offset, length: length(value)} | entries], child_values ++ value,
     offset + length(value)}
  end

  defp append_list_entry(value, _acc) do
    raise Error.new(:invalid_list_value, "LIST/MAP values must be lists, got #{inspect(value)}",
            source: :protocol
          )
  end

  defp encode_list_entry(%{offset: offset, length: length}) do
    [
      Writer.field(100, Writer.uleb128(offset)),
      Writer.field(101, Writer.uleb128(length)),
      Writer.end_object()
    ]
  end

  defp struct_child_value(nil, _name), do: nil

  defp struct_child_value(value, name) when is_map(value) do
    cond do
      Map.has_key?(value, name) ->
        Map.fetch!(value, name)

      is_binary(name) ->
        value
        |> Enum.find_value(fn
          {key, child_value} when is_atom(key) ->
            if Atom.to_string(key) == name, do: {:value, child_value}

          _entry ->
            nil
        end)
        |> case do
          {:value, child_value} -> child_value
          nil -> nil
        end

      true ->
        nil
    end
  end

  defp struct_child_value(_value, _name), do: nil

  defp read_child_vectors(binary, children, row_count) do
    with {:ok, count, rest} <- Reader.read_uleb128(binary),
         :ok <- expect_struct_child_count(children, count) do
      read_child_vectors(rest, children, row_count, count, [])
    end
  end

  defp read_child_vectors(rest, _children, _row_count, 0, vectors),
    do: {:ok, Enum.reverse(vectors), rest}

  defp read_child_vectors(binary, [child | children], row_count, remaining, vectors) do
    with {:ok, vector, rest} <- decode(binary, child.type, row_count) do
      read_child_vectors(rest, children, row_count, remaining - 1, [vector | vectors])
    end
  end

  defp read_child_vectors(_binary, [], _row_count, _remaining, _vectors) do
    error(:struct_child_mismatch, "struct has more child vectors than child types")
  end

  defp decode_fixed_values(blob, type, physical_type, row_count, validity) do
    with {:ok, values, <<>>} <-
           decode_fixed_values(blob, type, physical_type, row_count, validity, []) do
      {:ok, Enum.reverse(values)}
    end
  end

  defp decode_fixed_values(rest, _type, _physical_type, 0, _validity, values),
    do: {:ok, values, rest}

  defp decode_fixed_values(binary, type, physical_type, remaining, validity, values) do
    index = length(values)

    with {:ok, value, rest} <- Value.decode_fixed(binary, type, physical_type) do
      value = if valid?(validity, index), do: value, else: nil
      decode_fixed_values(rest, type, physical_type, remaining - 1, validity, [value | values])
    end
  end

  defp maybe_read_validity(binary, false, _row_count), do: {:ok, nil, binary}

  defp maybe_read_validity(binary, true, row_count),
    do: read_required(binary, 101, &read_validity(&1, row_count))

  defp read_validity(binary, row_count) do
    expected_size = div(row_count + 63, 64) * 8

    with {:ok, blob, rest} <- Reader.read_blob(binary),
         :ok <- expect_blob_size(blob, expected_size) do
      {:ok, blob, rest}
    end
  end

  defp read_selection(binary, row_count) do
    expected_size = row_count * 4

    with {:ok, blob, rest} <- Reader.read_blob(binary),
         :ok <- expect_blob_size(blob, expected_size) do
      {:ok, decode_selection(blob, []), rest}
    end
  end

  defp decode_selection(<<>>, indexes), do: Enum.reverse(indexes)

  defp decode_selection(<<index::little-unsigned-32, rest::binary>>, indexes),
    do: decode_selection(rest, [index | indexes])

  defp read_list_entries(binary, row_count) do
    with {:ok, entries, rest} <- Reader.read_list(binary, &read_list_entry/1) do
      if length(entries) == row_count do
        {:ok, entries, rest}
      else
        error(
          :list_entry_count_mismatch,
          "list vector serialized #{length(entries)} entries for #{row_count} rows"
        )
      end
    end
  end

  defp read_list_entry(binary), do: read_list_entry(binary, %{})

  defp read_list_entry(binary, entry) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, entry, rest}

        field_id == 100 ->
          with {:ok, offset, rest} <- Reader.read_uleb128(rest),
               do: read_list_entry(rest, Map.put(entry, :offset, offset))

        field_id == 101 ->
          with {:ok, length, rest} <- Reader.read_uleb128(rest),
               do: read_list_entry(rest, Map.put(entry, :length, length))

        true ->
          error(:unknown_list_entry_field, "unknown list entry field #{field_id}")
      end
    end
  end

  defp validate_list_entries(entries, list_size) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with {:ok, offset, length} <- list_entry_bounds(entry) do
        if offset + length <= list_size do
          {:cont, :ok}
        else
          {:halt,
           error(
             :list_entry_out_of_bounds,
             "list entry offset #{offset} with length #{length} exceeds child vector size #{list_size}"
           )}
        end
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp list_entry_bounds(%{offset: offset, length: length}), do: {:ok, offset, length}

  defp list_entry_bounds(entry) do
    error(
      :invalid_list_entry,
      "LIST entry must include offset and length fields, got #{inspect(entry)}"
    )
  end

  defp list_values(type, entries, child_values, validity) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {%{offset: offset, length: length}, row_index},
                                       {:ok, values} ->
      if valid?(validity, row_index) do
        value = Enum.slice(child_values, offset, length)

        case list_value(type, value) do
          {:ok, value} -> {:cont, {:ok, [value | values]}}
          {:error, _error} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, [nil | values]}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _error} = error -> error
    end
  end

  defp list_value(%{name: :map} = type, entries) do
    with :ok <- validate_map_child_type(type) do
      map_entries(entries)
    end
  end

  defp list_value(_type, entries), do: {:ok, entries}

  defp validate_map_child_type(type) do
    child_type = LogicalType.child_type(type)

    if child_type.name == :struct do
      children = LogicalType.struct_children(child_type)
      child_names = MapSet.new(children, & &1.name)

      cond do
        not MapSet.member?(child_names, "key") ->
          error(:invalid_map_type, "MAP child struct must include a key field")

        not MapSet.member?(child_names, "value") ->
          error(:invalid_map_type, "MAP child struct must include a value field")

        true ->
          :ok
      end
    else
      error(:invalid_map_type, "MAP child type must be STRUCT, got #{inspect(child_type.name)}")
    end
  end

  defp map_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, map} ->
      with {:ok, key, value} <- map_key_value(entry) do
        {:cont, {:ok, Map.put(map, key, value)}}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp map_key_value(%{"key" => key} = entry) do
    if Map.has_key?(entry, "value") do
      {:ok, key, Map.fetch!(entry, "value")}
    else
      invalid_map_entry(entry)
    end
  end

  defp map_key_value(%{key: key} = entry) do
    if Map.has_key?(entry, :value) do
      {:ok, key, Map.fetch!(entry, :value)}
    else
      invalid_map_entry(entry)
    end
  end

  defp map_key_value(other), do: invalid_map_entry(other)

  defp invalid_map_entry(entry) do
    error(
      :invalid_map_entry,
      "MAP entry must include key and value fields, got #{inspect(entry)}"
    )
  end

  defp select_dictionary_values(values, selection) do
    Enum.reduce_while(selection, {:ok, []}, fn index, {:ok, selected} ->
      case Enum.fetch(values, index) do
        {:ok, value} ->
          {:cont, {:ok, [value | selected]}}

        :error ->
          {:halt,
           error(:dictionary_index_out_of_range, "dictionary index #{index} is out of range")}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp valid?(nil, _index), do: true

  defp valid?(validity, index) do
    byte = :binary.at(validity, div(index, 8))
    (byte &&& 1 <<< rem(index, 8)) != 0
  end

  defp decode_string_like(%{name: name}, value) when name in [:blob, :geometry], do: value
  defp decode_string_like(%{name: :bit}, value), do: decode_bitstring(value)

  defp decode_string_like(%{name: :bignum}, value), do: decode_bignum(value)

  defp decode_string_like(_type, value) do
    if String.valid?(value) do
      value
    else
      raise Error.new(:invalid_string, "expected valid UTF-8 string vector value",
              source: :protocol
            )
    end
  end

  defp encode_bignum(value) when value < 0 do
    value
    |> abs()
    |> encode_bignum()
    |> :binary.bin_to_list()
    |> Enum.map(&(bnot(&1) &&& 0xFF))
    |> :binary.list_to_bin()
  end

  defp encode_bignum(value) do
    magnitude = encode_unsigned_big_endian(value)
    header = 0x80_0000 + byte_size(magnitude)
    <<header::unsigned-24, magnitude::binary>>
  end

  defp encode_unsigned_big_endian(0), do: <<0>>

  defp encode_unsigned_big_endian(value) do
    value
    |> Stream.unfold(fn
      0 -> nil
      integer -> {rem(integer, 256), div(integer, 256)}
    end)
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  defp decode_bignum(<<1::1, _rest::bitstring>> = value) do
    decode_positive_bignum(value)
  end

  defp decode_bignum(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map(&(bnot(&1) &&& 0xFF))
    |> :binary.list_to_bin()
    |> decode_positive_bignum()
    |> Kernel.*(-1)
  end

  defp decode_positive_bignum(<<header::unsigned-24, magnitude::binary>>)
       when header >= 0x80_0000 do
    size = header - 0x80_0000

    if byte_size(magnitude) == size do
      decode_unsigned_big_endian(magnitude)
    else
      raise Error.new(:invalid_bignum, "BIGNUM payload size does not match header",
              source: :protocol
            )
    end
  end

  defp decode_positive_bignum(_value) do
    raise Error.new(:invalid_bignum, "expected DuckDB BIGNUM payload", source: :protocol)
  end

  defp decode_unsigned_big_endian(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn byte, acc -> acc * 256 + byte end)
  end

  defp decode_bitstring(<<padding, bytes::binary>>) when padding in 0..7 do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> byte |> Integer.to_string(2) |> String.pad_leading(8, "0") end)
    |> String.slice(padding..-1//1)
  end

  defp decode_bitstring(_value) do
    raise Error.new(:invalid_bitstring, "expected DuckDB BIT payload", source: :protocol)
  end

  defp read_required(binary, expected_field_id, read_value) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary),
         :ok <- expect_field(field_id, expected_field_id) do
      read_value.(rest)
    end
  end

  defp expect_field(field_id, field_id), do: :ok

  defp expect_field(field_id, expected_field_id),
    do: error(:unexpected_field, "expected field #{expected_field_id}, got #{field_id}")

  defp expect_vector_end(field_id) do
    if field_id == QuackDB.Protocol.field_end(),
      do: :ok,
      else: error(:unexpected_vector_field, "unexpected vector field #{field_id}")
  end

  defp expect_array_size(type, size) do
    expected = LogicalType.array_size(type)

    if size == expected,
      do: :ok,
      else:
        error(:array_size_mismatch, "array vector serialized size #{size}, expected #{expected}")
  end

  defp expect_value_count(values, row_count, physical_type) do
    count = length(values)

    if count == row_count,
      do: :ok,
      else:
        error(
          :vector_value_count_mismatch,
          "#{physical_type} vector serialized #{count} values for #{row_count} rows"
        )
  end

  defp expect_struct_child_count(children, count) do
    expected = length(children)

    if count == expected,
      do: :ok,
      else:
        error(
          :struct_child_mismatch,
          "struct vector serialized #{count} child vectors for #{expected} child types"
        )
  end

  defp expect_blob_size(blob, size) when byte_size(blob) == size, do: :ok

  defp expect_blob_size(blob, size),
    do: error(:invalid_blob_size, "expected #{size} bytes, got #{byte_size(blob)}")

  defp vector_type(0), do: {:ok, :flat}
  defp vector_type(1), do: {:ok, :fsst}
  defp vector_type(2), do: {:ok, :constant}
  defp vector_type(3), do: {:ok, :dictionary}
  defp vector_type(4), do: {:ok, :sequence}
  defp vector_type(id), do: error(:unknown_vector_type, "unknown vector type #{id}")

  defp error(code, message), do: {:error, Error.new(code, message, source: :protocol)}
end

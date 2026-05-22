defmodule QuackDB.Protocol.DataChunk do
  @moduledoc false

  import Bitwise

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader

  defstruct row_count: 0, types: [], columns: []

  @type column :: %{type: LogicalType.t(), vector_type: atom(), values: [term()]}
  @type t :: %__MODULE__{
          row_count: non_neg_integer(),
          types: [LogicalType.t()],
          columns: [column()]
        }

  @spec decode_wrapper(binary()) :: Reader.read_result(t())
  def decode_wrapper(binary), do: decode_wrapper(binary, nil)

  @spec rows(t(), [String.t()] | nil) :: [[term()]]
  def rows(chunk, names \\ nil)

  def rows(%__MODULE__{row_count: 0}, _names), do: []

  def rows(%__MODULE__{} = chunk, _names) do
    for row_index <- 0..(chunk.row_count - 1)//1 do
      Enum.map(chunk.columns, fn column -> Enum.at(column.values, row_index) end)
    end
  end

  defp decode_wrapper(binary, chunk) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() and chunk != nil ->
          {:ok, chunk, rest}

        field_id == 300 ->
          with {:ok, chunk, rest} <- decode(rest) do
            decode_wrapper(rest, chunk)
          end

        true ->
          error(:invalid_data_chunk_wrapper, "expected DataChunkWrapper field 300")
      end
    end
  end

  defp decode(binary), do: decode_chunk(binary, %__MODULE__{})

  defp decode_chunk(binary, chunk) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          validate_chunk(chunk, rest)

        field_id == 100 ->
          with {:ok, row_count, rest} <- Reader.read_uleb128(rest) do
            decode_chunk(rest, %{chunk | row_count: row_count})
          end

        field_id == 101 ->
          with {:ok, types, rest} <- Reader.read_list(rest, &LogicalType.decode/1) do
            decode_chunk(rest, %{chunk | types: types})
          end

        field_id == 102 ->
          with {:ok, columns, rest} <- decode_vector_list(rest, chunk.types, chunk.row_count) do
            decode_chunk(rest, %{chunk | columns: columns})
          end

        true ->
          error(:unknown_data_chunk_field, "unknown data chunk field #{field_id}")
      end
    end
  end

  defp decode_vector_list(binary, types, row_count) do
    with {:ok, column_count, rest} <- Reader.read_uleb128(binary) do
      decode_vector_list(rest, types, row_count, column_count, [])
    end
  end

  defp decode_vector_list(rest, _types, _row_count, 0, columns) do
    {:ok, Enum.reverse(columns), rest}
  end

  defp decode_vector_list(binary, [type | types], row_count, remaining, columns) do
    with {:ok, column, rest} <- decode_vector(binary, type, row_count) do
      decode_vector_list(rest, types, row_count, remaining - 1, [column | columns])
    end
  end

  defp decode_vector_list(_binary, [], _row_count, _remaining, _columns) do
    error(:data_chunk_type_mismatch, "data chunk has more vectors than logical types")
  end

  defp decode_vector(binary, type, row_count) do
    decode_vector_object(binary, type, row_count, %{type: type, vector_type: :flat, values: []})
  end

  defp decode_vector_object(binary, type, row_count, vector) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, vector, rest}

        field_id == 90 ->
          with {:ok, vector_type_id, rest} <- Reader.read_uleb128(rest),
               {:ok, vector_type} <- vector_type(vector_type_id) do
            decode_vector_object(rest, type, row_count, %{vector | vector_type: vector_type})
          end

        true ->
          decode_vector_body(binary, type, row_count, vector.vector_type)
      end
    end
  end

  defp decode_vector_body(binary, type, row_count, :flat) do
    decode_flat_vector(binary, type, row_count, %{type: type, vector_type: :flat, values: []})
  end

  defp decode_vector_body(binary, type, row_count, :constant) do
    with {:ok, vector, rest} <- decode_vector_body(binary, type, min(row_count, 1), :flat) do
      value = List.first(vector.values)
      {:ok, %{vector | vector_type: :constant, values: List.duplicate(value, row_count)}, rest}
    end
  end

  defp decode_vector_body(_binary, _type, _row_count, vector_type) do
    error(:unsupported_vector_type, "#{vector_type} vectors are not implemented yet")
  end

  defp decode_flat_vector(binary, type, row_count, vector) do
    with {:ok, has_validity?, rest} <- read_required(binary, 100, &Reader.read_bool/1),
         {:ok, validity, rest} <- maybe_read_validity(rest, has_validity?, row_count),
         {:ok, values, rest} <- read_flat_values(rest, type, row_count, validity),
         {:ok, field_end, rest} <- Reader.read_field_id(rest),
         :ok <- expect_vector_end(field_end) do
      {:ok, %{vector | values: values}, rest}
    end
  end

  defp read_flat_values(binary, type, row_count, validity) do
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

  defp decode_variable_values(binary, type, :varchar, _row_count, validity) do
    read_blob_list = fn rest -> Reader.read_list(rest, &Reader.read_blob/1) end

    with {:ok, values, rest} <- read_required(binary, 102, read_blob_list) do
      values =
        values
        |> Enum.with_index()
        |> Enum.map(fn {value, index} ->
          if valid?(validity, index), do: decode_string_like(type, value), else: nil
        end)

      {:ok, values, rest}
    end
  end

  defp decode_variable_values(_binary, _type, physical_type, _row_count, _validity) do
    error(:unsupported_physical_type, "#{physical_type} vectors are not implemented yet")
  end

  defp decode_fixed_values(blob, type, physical_type, row_count, validity) do
    with {:ok, values, <<>>} <-
           decode_fixed_values(blob, type, physical_type, row_count, validity, []) do
      {:ok, Enum.reverse(values)}
    end
  end

  defp decode_fixed_values(rest, _type, _physical_type, 0, _validity, values) do
    {:ok, values, rest}
  end

  defp decode_fixed_values(binary, type, physical_type, remaining, validity, values) do
    index = length(values)

    with {:ok, value, rest} <- decode_fixed_value(binary, type, physical_type) do
      value = if valid?(validity, index), do: value, else: nil
      decode_fixed_values(rest, type, physical_type, remaining - 1, validity, [value | values])
    end
  end

  defp decode_fixed_value(binary, _type, :bool) do
    with {:ok, value, rest} <- Reader.read_uint8(binary), do: {:ok, value != 0, rest}
  end

  defp decode_fixed_value(binary, _type, :int8), do: Reader.read_int8(binary)
  defp decode_fixed_value(binary, _type, :uint8), do: Reader.read_uint8(binary)

  defp decode_fixed_value(binary, %{name: :decimal} = type, :int16) do
    with {:ok, value, rest} <- Reader.read_int16(binary), do: {:ok, decimal(type, value), rest}
  end

  defp decode_fixed_value(binary, _type, :int16), do: Reader.read_int16(binary)
  defp decode_fixed_value(binary, _type, :uint16), do: Reader.read_uint16(binary)

  defp decode_fixed_value(binary, %{name: :date}, :int32) do
    with {:ok, days, rest} <- Reader.read_int32(binary),
         do: {:ok, Date.add(~D[1970-01-01], days), rest}
  end

  defp decode_fixed_value(binary, %{name: :decimal} = type, :int32) do
    with {:ok, value, rest} <- Reader.read_int32(binary), do: {:ok, decimal(type, value), rest}
  end

  defp decode_fixed_value(binary, _type, :int32), do: Reader.read_int32(binary)
  defp decode_fixed_value(binary, _type, :uint32), do: Reader.read_uint32(binary)

  defp decode_fixed_value(binary, %{name: name}, :int64)
       when name in [
              :time,
              :time_ns,
              :timestamp_sec,
              :timestamp_ms,
              :timestamp,
              :timestamp_ns,
              :timestamp_tz
            ] do
    with {:ok, value, rest} <- Reader.read_int64(binary), do: {:ok, temporal(name, value), rest}
  end

  defp decode_fixed_value(binary, %{name: :decimal} = type, :int64) do
    with {:ok, value, rest} <- Reader.read_int64(binary), do: {:ok, decimal(type, value), rest}
  end

  defp decode_fixed_value(binary, _type, :int64), do: Reader.read_int64(binary)
  defp decode_fixed_value(binary, _type, :uint64), do: Reader.read_uint64(binary)
  defp decode_fixed_value(binary, _type, :float), do: Reader.read_float32(binary)
  defp decode_fixed_value(binary, _type, :double), do: Reader.read_float64(binary)

  defp decode_fixed_value(binary, %{name: :decimal} = type, :int128) do
    with {:ok, value, rest} <- read_int128(binary), do: {:ok, decimal(type, value), rest}
  end

  defp decode_fixed_value(binary, _type, :int128), do: read_int128(binary)

  defp decode_fixed_value(binary, _type, :uint128) do
    with {:ok, lower, rest} <- Reader.read_uint64(binary),
         {:ok, upper, rest} <- Reader.read_uint64(rest) do
      {:ok, upper * (1 <<< 64) + lower, rest}
    end
  end

  defp decode_fixed_value(binary, _type, :interval) do
    with {:ok, months, rest} <- Reader.read_int32(binary),
         {:ok, days, rest} <- Reader.read_int32(rest),
         {:ok, micros, rest} <- Reader.read_int64(rest) do
      {:ok, {:interval, months, days, micros}, rest}
    end
  end

  defp read_int128(binary) do
    with {:ok, lower, rest} <- Reader.read_uint64(binary),
         {:ok, upper, rest} <- Reader.read_int64(rest) do
      {:ok, upper * (1 <<< 64) + lower, rest}
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

  defp temporal(:time_ns, value), do: {:time_ns, value}
  defp temporal(:timestamp_ns, value), do: {:timestamp_ns, value}

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

  defp valid?(nil, _index), do: true

  defp valid?(validity, index) do
    byte = :binary.at(validity, div(index, 8))
    (byte &&& 1 <<< rem(index, 8)) != 0
  end

  defp decode_string_like(%{name: name}, value) when name in [:blob, :bit], do: value

  defp decode_string_like(_type, value) do
    if String.valid?(value) do
      value
    else
      raise Error.new(:invalid_string, "expected valid UTF-8 string vector value",
              source: :protocol
            )
    end
  end

  defp read_required(binary, expected_field_id, read_value) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary),
         :ok <- expect_field(field_id, expected_field_id) do
      read_value.(rest)
    end
  end

  defp expect_field(field_id, field_id), do: :ok

  defp expect_field(field_id, expected_field_id) do
    error(:unexpected_field, "expected field #{expected_field_id}, got #{field_id}")
  end

  defp expect_vector_end(field_id) do
    if field_id == QuackDB.Protocol.field_end() do
      :ok
    else
      error(:unexpected_vector_field, "unexpected vector field #{field_id}")
    end
  end

  defp expect_blob_size(blob, size) when byte_size(blob) == size, do: :ok

  defp expect_blob_size(blob, size),
    do: error(:invalid_blob_size, "expected #{size} bytes, got #{byte_size(blob)}")

  defp validate_chunk(%__MODULE__{types: types, columns: columns} = chunk, rest)
       when length(types) == length(columns) do
    {:ok, chunk, rest}
  end

  defp validate_chunk(%__MODULE__{types: types, columns: columns}, _rest) do
    error(
      :data_chunk_type_mismatch,
      "data chunk has #{length(types)} types and #{length(columns)} columns"
    )
  end

  defp vector_type(0), do: {:ok, :flat}
  defp vector_type(1), do: {:ok, :fsst}
  defp vector_type(2), do: {:ok, :constant}
  defp vector_type(3), do: {:ok, :dictionary}
  defp vector_type(4), do: {:ok, :sequence}
  defp vector_type(id), do: error(:unknown_vector_type, "unknown vector type #{id}")

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

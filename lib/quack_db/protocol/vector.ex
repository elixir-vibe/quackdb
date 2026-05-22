defmodule QuackDB.Protocol.Vector do
  @moduledoc """
  Decoder for DuckDB vector encodings inside Quack data chunks.

  Handles flat, constant, dictionary, and sequence vectors plus nested DuckDB
  logical types such as `LIST`, `STRUCT`, `ARRAY`, and `MAP`.
  """

  import Bitwise

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Value

  @type t :: %{type: LogicalType.t(), vector_type: atom(), values: [term()]}

  @spec decode(binary(), LogicalType.t(), non_neg_integer()) :: Reader.read_result(t())
  def decode(binary, type, row_count) do
    decode_object(binary, type, row_count, %{type: type, vector_type: :flat, values: []})
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
    with {:ok, has_validity?, rest} <- read_required(binary, 100, &Reader.read_bool/1),
         {:ok, validity, rest} <- maybe_read_validity(rest, has_validity?, row_count),
         {:ok, values, rest} <- read_values(rest, type, row_count, validity),
         {:ok, field_end, rest} <- Reader.read_field_id(rest),
         :ok <- expect_vector_end(field_end) do
      {:ok, %{vector | values: values}, rest}
    end
  end

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
      values =
        entries
        |> Enum.with_index()
        |> Enum.map(fn {%{offset: offset, length: length}, row_index} ->
          if valid?(validity, row_index) do
            value = Enum.slice(child_vector.values, offset, length)
            if type.name == :map, do: map_entries(value), else: value
          else
            nil
          end
        end)

      {:ok, values, rest}
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

  defp read_child_vectors(binary, children, row_count) do
    with {:ok, count, rest} <- Reader.read_uleb128(binary) do
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

  defp map_entries(entries) do
    Enum.reduce(entries, %{}, fn
      %{"key" => key, "value" => value}, map -> Map.put(map, key, value)
      %{key: key, value: value}, map -> Map.put(map, key, value)
      other, map -> Map.put(map, other, nil)
    end)
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

  defp decode_string_like(%{name: :blob}, value), do: value
  defp decode_string_like(%{name: :bit}, value), do: decode_bitstring(value)

  defp decode_string_like(%{name: :bignum}, _value) do
    raise Error.new(:unsupported_type, "BIGNUM values are not implemented yet", source: :protocol)
  end

  defp decode_string_like(_type, value) do
    if String.valid?(value) do
      value
    else
      raise Error.new(:invalid_string, "expected valid UTF-8 string vector value",
              source: :protocol
            )
    end
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

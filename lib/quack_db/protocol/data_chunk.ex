defmodule QuackDB.Protocol.DataChunk do
  @moduledoc false

  import Bitwise

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Value

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

  defp decode_vector_body(binary, type, row_count, :dictionary) do
    with {:ok, selection, rest} <- read_required(binary, 91, &read_selection(&1, row_count)),
         {:ok, dictionary_count, rest} <- read_required(rest, 92, &Reader.read_uleb128/1),
         {:ok, dictionary, rest} <-
           decode_vector_object(rest, type, dictionary_count, %{
             type: type,
             vector_type: :flat,
             values: []
           }),
         {:ok, values} <- select_dictionary_values(dictionary.values, selection) do
      {:ok, %{type: type, vector_type: :dictionary, values: values}, rest}
    end
  end

  defp decode_vector_body(binary, type, row_count, :sequence) do
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

  defp decode_selection(<<index::little-unsigned-32, rest::binary>>, indexes) do
    decode_selection(rest, [index | indexes])
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

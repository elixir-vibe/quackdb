defmodule QuackDB.Protocol.DataChunk do
  @moduledoc false

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Vector

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
    with {:ok, column, rest} <- Vector.decode(binary, type, row_count) do
      decode_vector_list(rest, types, row_count, remaining - 1, [column | columns])
    end
  end

  defp decode_vector_list(_binary, [], _row_count, _remaining, _columns) do
    error(:data_chunk_type_mismatch, "data chunk has more vectors than logical types")
  end

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

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

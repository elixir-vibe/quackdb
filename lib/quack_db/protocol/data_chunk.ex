defmodule QuackDB.Protocol.DataChunk do
  @moduledoc """
  Decoder for DuckDB Quack `DataChunk` payloads.

  Data chunks carry a row count, logical types, and column vectors. This module
  validates the chunk wrapper and converts decoded vectors into row-oriented
  results for the current DBConnection/Ecto-facing API.
  """

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Vector
  alias QuackDB.Protocol.Writer

  defstruct row_count: 0, types: [], columns: []

  @type column :: %{type: LogicalType.t(), vector_type: atom(), values: [term()]}
  @type t :: %__MODULE__{
          row_count: non_neg_integer(),
          types: [LogicalType.t()],
          columns: [column()]
        }

  @spec encode_wrapper(t()) :: iodata()
  def encode_wrapper(%__MODULE__{} = chunk) do
    [
      Writer.field(300, encode(chunk)),
      Writer.end_object()
    ]
  end

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = chunk) do
    [
      Writer.field(100, Writer.uleb128(chunk.row_count)),
      Writer.field(
        101,
        Writer.list(chunk.types, &LogicalType.encode/1)
      ),
      Writer.field(
        102,
        Writer.list(chunk.columns, &encode_column/1)
      ),
      Writer.end_object()
    ]
  end

  @type row :: map() | Keyword.t()

  @spec from_rows([row()], Keyword.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_rows(rows, options \\ []) when is_list(rows) do
    with {:ok, columns} <- columns_from_rows(rows, options) do
      types = Enum.map(columns, & &1.type)

      vectors =
        Enum.map(columns, fn column ->
          values = Enum.map(rows, &fetch_row_value(&1, column.name))
          %{type: column.type, vector_type: :flat, values: values}
        end)

      {:ok, %__MODULE__{row_count: length(rows), types: types, columns: vectors}}
    end
  end

  @spec columns_from_rows([row()], Keyword.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def columns_from_rows(rows, options \\ []) when is_list(rows) do
    resolve_columns(rows, Keyword.get(options, :columns))
  end

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

  defp encode_column(%{type: type, values: values}) do
    Vector.encode(type, values, length(values))
  end

  defp resolve_columns(rows, nil), do: infer_columns(rows)

  defp resolve_columns(_rows, columns) when is_list(columns) do
    columns
    |> Enum.map(&normalize_column/1)
    |> collect_ok()
  end

  defp infer_columns([]) do
    error(:missing_append_columns, "cannot infer append columns from an empty row set")
  end

  defp infer_columns([first | _] = rows) when is_list(first) do
    if Keyword.keyword?(first) do
      first
      |> Keyword.keys()
      |> infer_columns_from_names(rows)
    else
      error(:invalid_append_row, "append rows must be maps or keyword lists")
    end
  end

  defp infer_columns([first | _] = rows) when is_map(first) do
    first
    |> Map.keys()
    |> infer_columns_from_names(rows)
  end

  defp infer_columns_from_names(names, rows) do
    names
    |> Enum.map(fn name ->
      values = Enum.map(rows, &fetch_row_value(&1, name))

      with {:ok, type} <- infer_type(values) do
        {:ok, %{name: name, type: type}}
      end
    end)
    |> collect_ok()
  end

  defp normalize_column({name, type}) do
    with {:ok, type} <- normalize_type(type) do
      {:ok, %{name: name, type: type}}
    end
  end

  defp normalize_column(%{name: name, type: type}), do: normalize_column({name, type})

  defp normalize_column(column) when is_atom(column) or is_binary(column) do
    error(:missing_append_column_type, "column #{inspect(column)} is missing an append type")
  end

  defp normalize_column(column) do
    error(:invalid_append_column, "invalid append column #{inspect(column)}")
  end

  defp normalize_type(%LogicalType{} = type), do: {:ok, type}
  defp normalize_type(type) when is_atom(type), do: {:ok, LogicalType.new(type)}

  defp normalize_type({:decimal, width, scale}),
    do: {:ok, LogicalType.new(:decimal, %{type: 2, width: width, scale: scale})}

  defp normalize_type({:list, child_type}),
    do:
      with(
        {:ok, child} <- normalize_type(child_type),
        do: {:ok, LogicalType.new(:list, %{type: 4, child_type: child})}
      )

  defp normalize_type({:array, child_type, size}),
    do:
      with(
        {:ok, child} <- normalize_type(child_type),
        do: {:ok, LogicalType.new(:array, %{type: 9, child_type: child, size: size})}
      )

  defp normalize_type(type) do
    error(:invalid_append_type, "invalid append type #{inspect(type)}")
  end

  defp infer_type(values) do
    case Enum.find(values, &(!is_nil(&1))) do
      nil ->
        error(:missing_append_column_type, "cannot infer append type from only nil values")

      value when is_boolean(value) ->
        {:ok, LogicalType.new(:boolean)}

      value when is_integer(value) and value in -2_147_483_648..2_147_483_647 ->
        {:ok, LogicalType.new(:integer)}

      value when is_integer(value) ->
        {:ok, LogicalType.new(:bigint)}

      value when is_float(value) ->
        {:ok, LogicalType.new(:double)}

      %Date{} ->
        {:ok, LogicalType.new(:date)}

      %Time{} ->
        {:ok, LogicalType.new(:time)}

      %NaiveDateTime{} ->
        {:ok, LogicalType.new(:timestamp)}

      %DateTime{} ->
        {:ok, LogicalType.new(:timestamp_tz)}

      %Decimal{} = decimal ->
        {:ok, decimal_type(decimal)}

      value when is_binary(value) ->
        {:ok, LogicalType.new(:varchar)}

      value when is_list(value) ->
        infer_list_type(values)

      value when is_map(value) ->
        infer_struct_type(values, value)

      value ->
        error(:invalid_append_type, "cannot infer append type for #{inspect(value)}")
    end
  end

  defp infer_list_type(values) do
    child_values = Enum.flat_map(values, fn value -> if is_list(value), do: value, else: [] end)

    with {:ok, child_type} <- infer_type(child_values) do
      {:ok, LogicalType.new(:list, %{type: 4, child_type: child_type})}
    end
  end

  defp infer_struct_type(values, sample) do
    children =
      sample
      |> Map.keys()
      |> Enum.map(fn name ->
        child_values =
          Enum.map(values, fn value ->
            if is_map(value), do: fetch_row_value(value, name), else: nil
          end)

        with {:ok, type} <- infer_type(child_values) do
          {:ok, %{name: to_string(name), type: type}}
        end
      end)

    with {:ok, children} <- collect_ok(children) do
      {:ok, LogicalType.new(:struct, %{type: 5, children: children})}
    end
  end

  defp decimal_type(%Decimal{coef: coefficient, exp: exponent}) do
    scale = max(-exponent, 0)
    width = min(max(coefficient |> abs() |> Integer.digits() |> length(), scale + 1), 38)
    LogicalType.new(:decimal, %{type: 2, width: width, scale: scale})
  end

  defp fetch_row_value(row, name) when is_list(row) do
    if Keyword.keyword?(row) do
      keyword_value(row, name)
    end
  end

  defp fetch_row_value(row, name) when is_map(row) do
    cond do
      Map.has_key?(row, name) ->
        Map.fetch!(row, name)

      is_atom(name) and Map.has_key?(row, to_string(name)) ->
        Map.fetch!(row, to_string(name))

      is_binary(name) ->
        row
        |> Enum.find_value(fn
          {key, value} when is_atom(key) -> if Atom.to_string(key) == name, do: {:value, value}
          _entry -> nil
        end)
        |> case do
          {:value, value} -> value
          nil -> nil
        end

      true ->
        nil
    end
  end

  defp keyword_value(row, name) do
    cond do
      is_atom(name) and Keyword.has_key?(row, name) ->
        Keyword.fetch!(row, name)

      is_binary(name) ->
        row
        |> Enum.find_value(fn
          {key, value} when is_atom(key) -> if Atom.to_string(key) == name, do: {:value, value}
          _entry -> nil
        end)
        |> case do
          {:value, value} -> value
          nil -> nil
        end

      true ->
        nil
    end
  end

  defp collect_ok(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
      {:error, _error} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
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

  defp validate_chunk(%__MODULE__{types: types, columns: columns} = chunk, rest) do
    if Enum.count(types) == Enum.count(columns) do
      {:ok, chunk, rest}
    else
      error(
        :data_chunk_type_mismatch,
        "data chunk has #{Enum.count(types)} types and #{Enum.count(columns)} columns"
      )
    end
  end

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

defimpl Inspect, for: QuackDB.Protocol.DataChunk do
  import Inspect.Algebra

  def inspect(chunk, opts) do
    fields = [
      rows: chunk.row_count,
      columns: length(chunk.columns),
      types: Enum.map(chunk.types, &type_name/1)
    ]

    concat(QuackDB.Inspect.container("QuackDB.DataChunk", fields, opts))
  end

  defp type_name(%{name: name}) when not is_nil(name), do: name
  defp type_name(%{id: id}), do: id
end

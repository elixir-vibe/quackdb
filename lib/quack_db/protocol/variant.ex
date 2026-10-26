defmodule QuackDB.Protocol.Variant do
  @moduledoc """
  Decodes DuckDB `VARIANT` values into Elixir terms.

  A VARIANT vector travels in one of two layouts:

    * unshredded: a STRUCT of `keys`, `children`, `values`, and a `data` blob
      per row, where `values[0]` is the root value;
    * shredded: a STRUCT of the unshredded leftovers and a typed tree, where
      each node is a `STRUCT(typed_value, untyped_value_index)` wrapper and
      leftover values are referenced by 1-based index into the unshredded row.

  Both decode to the same terms: objects become maps with string keys, arrays
  become lists, and scalars decode like the matching DuckDB column type.
  VARIANT `NULL`s inside objects and arrays become `nil`.
  """

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Value

  # VariantLogicalType ids to the column type whose fixed-width encoding the
  # value payload uses.
  @fixed_types %{
    3 => :tinyint,
    4 => :smallint,
    5 => :integer,
    6 => :bigint,
    7 => :hugeint,
    8 => :utinyint,
    9 => :usmallint,
    10 => :uinteger,
    11 => :ubigint,
    12 => :uhugeint,
    13 => :float,
    14 => :double,
    18 => :uuid,
    19 => :date,
    20 => :time,
    21 => :time_ns,
    22 => :timestamp_sec,
    23 => :timestamp_ms,
    24 => :timestamp,
    25 => :timestamp_ns,
    26 => :time_tz,
    27 => :timestamp_tz,
    28 => :interval,
    34 => :timestamp_tz_ns
  }

  @string_types %{16 => :varchar, 17 => :blob, 31 => :bignum, 32 => :bit, 33 => :geometry}

  # Built once at compile time: {logical type, physical type} per type id.
  @fixed_decoders Map.new(@fixed_types, fn {id, name} ->
                    type = LogicalType.new(name)
                    {id, {type, LogicalType.physical_type(type)}}
                  end)
  @string_decoders Map.new(@string_types, fn {id, name} -> {id, LogicalType.new(name)} end)

  @null 0
  @bool_true 1
  @bool_false 2
  @decimal 15
  @object 29
  @array 30

  @doc """
  Decodes unshredded VARIANT rows, as decoded from the VARIANT's STRUCT
  layout. A `nil` row is a SQL `NULL`.
  """
  @spec decode_rows([map() | nil]) :: {:ok, [term()]} | {:error, Error.t()}
  def decode_rows(rows) do
    collect(rows, fn
      nil -> {:ok, nil}
      row -> row |> index_row() |> value(0)
    end)
  end

  @doc """
  Decodes shredded VARIANT rows: `unshredded` holds the leftover VARIANT rows
  and `shredded` the typed wrapper values, decoded as `shredded_type`.
  """
  @spec decode_shredded([map() | nil], LogicalType.t(), [term()]) ::
          {:ok, [term()]} | {:error, Error.t()}
  def decode_shredded(unshredded, shredded_type, shredded) do
    unshredded
    |> Enum.zip(shredded)
    |> collect(fn
      {_row, nil} ->
        {:ok, nil}

      {row, wrapper} ->
        case resolve(shredded_type, wrapper, index_row(row)) do
          {:ok, :missing} -> {:ok, nil}
          other -> other
        end
    end)
  end

  defp resolve(%LogicalType{name: :struct} = type, wrapper, row) do
    [typed_child | overlay_child] = LogicalType.struct_children(type)
    typed = Map.get(wrapper, typed_child.name)
    untyped = with [child] <- overlay_child, do: Map.get(wrapper, child.name)

    cond do
      typed != nil -> typed_value(typed_child.type, typed, untyped, row)
      overlay_child == [] or untyped == nil -> {:ok, nil}
      untyped == 0 -> {:ok, :missing}
      true -> value(row, untyped - 1)
    end
  end

  # A leaf that is not wrapped is a fully consistent primitive column.
  defp resolve(_type, leaf, _row), do: {:ok, leaf}

  defp typed_value(%LogicalType{name: :struct} = type, fields, overlay, row) do
    with {:ok, typed} <- typed_fields(type, fields, row),
         {:ok, leftover} <- overlay_fields(overlay, row) do
      {:ok, Map.merge(leftover, typed)}
    end
  end

  defp typed_value(%LogicalType{name: :list} = type, elements, _overlay, row) do
    element_type = LogicalType.child_type(type)

    collect(elements, fn element ->
      case resolve(element_type, element, row) do
        {:ok, :missing} -> {:ok, nil}
        other -> other
      end
    end)
  end

  defp typed_value(_type, value, _overlay, _row), do: {:ok, value}

  defp typed_fields(type, fields, row) do
    type
    |> LogicalType.struct_children()
    |> Enum.reduce_while({:ok, %{}}, fn child, {:ok, acc} ->
      case resolve(child.type, Map.get(fields, child.name), row) do
        {:ok, :missing} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, child.name, value)}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp overlay_fields(overlay, _row) when overlay in [nil, 0], do: {:ok, %{}}
  defp overlay_fields(overlay, row), do: value(row, overlay - 1)

  # A row's keys, children, and values are looked up by index while walking
  # its tree, so they become tuples once instead of being walked per lookup.
  defp index_row(nil), do: nil

  defp index_row(row) do
    %{
      keys: to_tuple(row["keys"]),
      children: to_tuple(row["children"]),
      values: to_tuple(row["values"]),
      data: row["data"]
    }
  end

  defp to_tuple(nil), do: {}
  defp to_tuple(list), do: List.to_tuple(list)

  defp value(row, index) do
    with {:ok, %{"type_id" => type_id, "byte_offset" => offset}} <- fetch(row.values, index),
         {:ok, payload} <- payload(row.data, offset) do
      decode_value(type_id, payload, row)
    end
  end

  defp decode_value(@null, _payload, _row), do: {:ok, nil}
  defp decode_value(@bool_true, _payload, _row), do: {:ok, true}
  defp decode_value(@bool_false, _payload, _row), do: {:ok, false}

  defp decode_value(type_id, payload, _row) when is_map_key(@fixed_decoders, type_id) do
    {type, physical_type} = Map.fetch!(@fixed_decoders, type_id)

    with {:ok, value, _rest} <- Value.decode_fixed(payload, type, physical_type) do
      {:ok, value}
    end
  end

  defp decode_value(type_id, payload, _row) when is_map_key(@string_decoders, type_id) do
    type = Map.fetch!(@string_decoders, type_id)

    with {:ok, bytes, _rest} <- Reader.read_blob(payload) do
      {:ok, QuackDB.Protocol.Vector.decode_string_value(type, bytes)}
    end
  end

  defp decode_value(@decimal, payload, _row) do
    with {:ok, width, rest} <- Reader.read_uleb128(payload),
         {:ok, scale, rest} <- Reader.read_uleb128(rest) do
      type = LogicalType.new(:decimal, LogicalType.decimal_info(width, scale))

      with {:ok, value, _rest} <- Value.decode_fixed(rest, type, LogicalType.physical_type(type)) do
        {:ok, value}
      end
    end
  end

  defp decode_value(@array, payload, row) do
    with {:ok, children} <- nested_children(payload, row) do
      collect(children, &value(row, &1["values_index"]))
    end
  end

  defp decode_value(@object, payload, row) do
    with {:ok, children} <- nested_children(payload, row) do
      Enum.reduce_while(children, {:ok, %{}}, fn child, {:ok, acc} ->
        with {:ok, key} <- fetch(row.keys, child["keys_index"]),
             {:ok, value} <- value(row, child["values_index"]) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          {:error, _error} = error -> {:halt, error}
        end
      end)
    end
  end

  defp decode_value(type_id, _payload, _row) do
    error(:unsupported_variant_type, "VARIANT value type #{type_id} is not supported")
  end

  defp nested_children(payload, row) do
    with {:ok, count, rest} <- Reader.read_uleb128(payload),
         {:ok, first} <- first_child(count, rest) do
      collect(first..(first + count - 1)//1, &fetch(row.children, &1))
    end
  end

  defp first_child(0, _rest), do: {:ok, 0}

  defp first_child(_count, rest) do
    with {:ok, first, _rest} <- Reader.read_uleb128(rest), do: {:ok, first}
  end

  defp payload(data, offset) when is_binary(data) and byte_size(data) >= offset do
    {:ok, binary_part(data, offset, byte_size(data) - offset)}
  end

  defp payload(_data, offset),
    do: error(:invalid_variant, "VARIANT byte offset #{offset} is outside its data")

  defp fetch(tuple, index) when is_integer(index) and index >= 0 and index < tuple_size(tuple),
    do: {:ok, elem(tuple, index)}

  defp fetch(_tuple, index),
    do: error(:invalid_variant, "VARIANT index #{inspect(index)} is out of range")

  defp collect(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp error(code, message), do: {:error, Error.new(code, message, source: :protocol)}
end

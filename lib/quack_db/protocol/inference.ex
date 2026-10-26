defmodule QuackDB.Protocol.Inference do
  @moduledoc false

  # Infers an append column's DuckDB type from its Elixir values. Every value
  # takes part: integers and decimals widen while that stays exact, integers
  # join floats while a DOUBLE holds them exactly, and struct fields are the
  # union of the maps' keys. Any other mix of shapes is an error naming the
  # column, since picking one type would truncate, drop, or NULL the rest.

  alias QuackDB.Error
  alias QuackDB.Protocol.LogicalType

  @int32 -0x8000_0000..0x7FFF_FFFF
  @int64 -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF
  @int128 -0x8000_0000_0000_0000_0000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF
  @exact_double -0x20_0000_0000_0000..0x20_0000_0000_0000
  @max_decimal_width 38

  @scalar_names %{
    boolean: "boolean",
    date: "Date",
    time: "Time",
    timestamp: "NaiveDateTime",
    timestamp_tz: "DateTime",
    varchar: "string"
  }

  @spec infer(String.t(), [term()]) :: {:ok, LogicalType.t()} | {:error, Error.t()}
  def infer(column, values) when is_binary(column) and is_list(values) do
    with {:ok, shape} <- shape_of(column, values, nil), do: to_type(column, shape)
  end

  # A shape is what the values seen so far need: nil before any value,
  # {:integer, min, max}, :double, {:decimal, integer_digits, scale},
  # {:scalar, name}, {:list, element_shape}, or {:struct, [{key, shape}]}.
  # Paths name the value in errors and stay iodata until one is raised.
  defp shape_of(_path, [], shape), do: {:ok, shape}
  defp shape_of(path, [nil | rest], shape), do: shape_of(path, rest, shape)

  # Most columns hold one kind of value, so values that leave the shape as it
  # is skip building a shape of their own.
  defp shape_of(path, [value | rest], {:integer, min, max} = shape)
       when is_integer(value) and value >= min and value <= max,
       do: shape_of(path, rest, shape)

  defp shape_of(path, [value | rest], {:integer, min, max}) when is_integer(value),
    do: shape_of(path, rest, {:integer, min(min, value), max(max, value)})

  defp shape_of(path, [value | rest], :double) when is_float(value),
    do: shape_of(path, rest, :double)

  defp shape_of(path, [value | rest], {:scalar, :varchar} = shape) when is_binary(value),
    do: shape_of(path, rest, shape)

  defp shape_of(path, [value | rest], {:scalar, :boolean} = shape) when is_boolean(value),
    do: shape_of(path, rest, shape)

  defp shape_of(path, [value | rest], shape) do
    with {:ok, value_shape} <- value_shape(path, value),
         {:ok, shape} <- unify(path, shape, value_shape) do
      shape_of(path, rest, shape)
    end
  end

  defp value_shape(_path, value) when is_boolean(value), do: {:ok, {:scalar, :boolean}}
  defp value_shape(_path, value) when is_integer(value), do: {:ok, {:integer, value, value}}
  defp value_shape(_path, value) when is_float(value), do: {:ok, :double}
  defp value_shape(_path, value) when is_binary(value), do: {:ok, {:scalar, :varchar}}
  defp value_shape(_path, %Date{}), do: {:ok, {:scalar, :date}}
  defp value_shape(_path, %Time{}), do: {:ok, {:scalar, :time}}
  defp value_shape(_path, %NaiveDateTime{}), do: {:ok, {:scalar, :timestamp}}
  defp value_shape(_path, %DateTime{}), do: {:ok, {:scalar, :timestamp_tz}}

  defp value_shape(_path, %Decimal{coef: coefficient, exp: exponent})
       when is_integer(coefficient) do
    digits = coefficient |> Integer.digits() |> length()
    {:ok, {:decimal, max(digits + exponent, 1), max(-exponent, 0)}}
  end

  defp value_shape(path, value) when is_list(value) do
    with {:ok, element} <- shape_of([path, "[]"], value, nil), do: {:ok, {:list, element}}
  end

  defp value_shape(path, value) when is_map(value) and not is_struct(value),
    do: map_shape(path, Map.to_list(value), [])

  defp value_shape(path, value) do
    error(
      :invalid_append_type,
      ["cannot infer the append type of ", path, " for ", inspect(value)]
    )
  end

  defp map_shape(_path, [], fields), do: {:ok, {:struct, Enum.reverse(fields)}}

  defp map_shape(path, [{key, value} | rest], fields) do
    with {:ok, shape} <- shape_of(field_path(path, key), [value], nil),
         do: map_shape(path, rest, [{key, shape} | fields])
  end

  defp unify(_path, nil, shape), do: {:ok, shape}
  defp unify(_path, shape, nil), do: {:ok, shape}
  defp unify(_path, shape, shape), do: {:ok, shape}

  defp unify(_path, {:integer, min_a, max_a}, {:integer, min_b, max_b}),
    do: {:ok, {:integer, min(min_a, min_b), max(max_a, max_b)}}

  defp unify(path, {:integer, _min, _max} = integers, :double), do: join_double(path, integers)
  defp unify(path, :double, {:integer, _min, _max} = integers), do: join_double(path, integers)

  defp unify(_path, {:integer, min, max}, {:decimal, digits, scale}),
    do: {:ok, {:decimal, max(digits, integer_digits(min, max)), scale}}

  defp unify(path, {:decimal, _digits, _scale} = decimal, {:integer, _min, _max} = integers),
    do: unify(path, integers, decimal)

  defp unify(_path, {:decimal, digits_a, scale_a}, {:decimal, digits_b, scale_b}),
    do: {:ok, {:decimal, max(digits_a, digits_b), max(scale_a, scale_b)}}

  defp unify(path, {:list, element_a}, {:list, element_b}) do
    with {:ok, element} <- unify([path, "[]"], element_a, element_b),
         do: {:ok, {:list, element}}
  end

  defp unify(path, {:struct, fields_a}, {:struct, fields_b}),
    do: unify_fields(path, fields_a, fields_b, [])

  defp unify(path, shape_a, shape_b) do
    error(:mixed_append_types, [
      "append column ",
      path,
      " mixes ",
      describe(shape_a),
      " and ",
      describe(shape_b),
      " values; declare its type with :columns, or :variant to keep mixed values"
    ])
  end

  # Keys new to the struct go after the known ones, in the order they appear.
  defp unify_fields(_path, fields, [], added),
    do: {:ok, {:struct, fields ++ Enum.reverse(added)}}

  defp unify_fields(path, fields, [{key, shape_b} | rest], added) do
    case List.keyfind(fields, key, 0) do
      nil ->
        unify_fields(path, fields, rest, [{key, shape_b} | added])

      {^key, shape_a} ->
        with {:ok, shape} <- unify(field_path(path, key), shape_a, shape_b),
             do: unify_fields(path, List.keyreplace(fields, key, 0, {key, shape}), rest, added)
    end
  end

  defp join_double(_path, {:integer, min, max})
       when min in @exact_double and max in @exact_double,
       do: {:ok, :double}

  defp join_double(path, _integers) do
    error(:mixed_append_types, [
      "append column ",
      path,
      " mixes floats with integers a DOUBLE cannot hold exactly; declare its type with :columns"
    ])
  end

  defp integer_digits(min, max),
    do: max(abs(min), abs(max)) |> Integer.digits() |> length()

  defp to_type(path, nil) do
    error(:missing_append_column_type, [
      "cannot infer the append type of ",
      path,
      " from only nil values"
    ])
  end

  defp to_type(_path, {:integer, min, max}) when min in @int32 and max in @int32,
    do: {:ok, LogicalType.new(:integer)}

  defp to_type(_path, {:integer, min, max}) when min in @int64 and max in @int64,
    do: {:ok, LogicalType.new(:bigint)}

  defp to_type(_path, {:integer, min, max}) when min in @int128 and max in @int128,
    do: {:ok, LogicalType.new(:hugeint)}

  defp to_type(path, {:integer, _min, _max}),
    do: error(:invalid_append_type, ["append column ", path, " has integers beyond HUGEINT"])

  defp to_type(_path, :double), do: {:ok, LogicalType.new(:double)}

  defp to_type(_path, {:decimal, digits, scale}) when digits + scale <= @max_decimal_width,
    do: {:ok, LogicalType.new(:decimal, LogicalType.decimal_info(digits + scale, scale))}

  defp to_type(path, {:decimal, _digits, _scale}) do
    error(:invalid_append_type, [
      "append column ",
      path,
      " needs more than #{@max_decimal_width} decimal digits; declare its type with :columns"
    ])
  end

  defp to_type(_path, {:scalar, name}), do: {:ok, LogicalType.new(name)}

  defp to_type(path, {:list, element}) do
    with {:ok, child_type} <- to_type([path, "[]"], element),
         do: {:ok, LogicalType.new(:list, %{type: 4, child_type: child_type})}
  end

  defp to_type(path, {:struct, fields}), do: struct_type(path, fields, [])

  defp struct_type(_path, [], children),
    do: {:ok, LogicalType.new(:struct, %{type: 5, children: Enum.reverse(children)})}

  defp struct_type(path, [{key, shape} | rest], children) do
    with {:ok, type} <- to_type(field_path(path, key), shape),
         do: struct_type(path, rest, [%{name: to_string(key), type: type} | children])
  end

  defp field_path(path, key), do: [path, ?., to_string(key)]

  defp describe({:integer, _min, _max}), do: "integer"
  defp describe(:double), do: "float"
  defp describe({:decimal, _digits, _scale}), do: "Decimal"
  defp describe({:scalar, name}), do: Map.fetch!(@scalar_names, name)
  defp describe({:list, _element}), do: "list"
  defp describe({:struct, _fields}), do: "map"

  defp error(code, message),
    do: {:error, Error.new(code, IO.iodata_to_binary(message), source: :protocol)}
end

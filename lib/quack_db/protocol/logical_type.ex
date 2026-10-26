defmodule QuackDB.Protocol.LogicalType do
  @moduledoc """
  DuckDB logical type encoding helpers for Quack protocol messages.
  """

  alias QuackDB.Error
  alias QuackDB.Protocol.Reader

  import QuackDB.Protocol.Writer,
    only: [end_object: 0, field: 2, list: 2, nullable: 2, string: 1, uleb128: 1]

  defstruct [:id, :name, :type_info]

  # Temporal types DuckDB stores as one signed 64-bit integer.
  @int64_temporal [
    :time,
    :time_ns,
    :time_tz,
    :timestamp,
    :timestamp_ms,
    :timestamp_ns,
    :timestamp_sec,
    :timestamp_tz,
    :timestamp_tz_ns
  ]

  @doc "Guards temporal type names that DuckDB stores as one signed 64-bit integer."
  defguard is_int64_temporal(name) when name in @int64_temporal

  @type id :: non_neg_integer()
  @type t :: %__MODULE__{id: id(), name: atom() | nil, type_info: map() | nil}

  @ids %{
    sqlnull: 1,
    boolean: 10,
    tinyint: 11,
    smallint: 12,
    integer: 13,
    bigint: 14,
    date: 15,
    time: 16,
    timestamp_sec: 17,
    timestamp_ms: 18,
    timestamp: 19,
    timestamp_ns: 20,
    decimal: 21,
    float: 22,
    double: 23,
    char: 24,
    varchar: 25,
    blob: 26,
    interval: 27,
    utinyint: 28,
    usmallint: 29,
    uinteger: 30,
    ubigint: 31,
    timestamp_tz: 32,
    timestamp_tz_ns: 33,
    time_tz: 34,
    time_ns: 35,
    bit: 36,
    bignum: 39,
    uhugeint: 49,
    hugeint: 50,
    uuid: 54,
    geometry: 60,
    struct: 100,
    list: 101,
    map: 102,
    enum: 104,
    array: 108,
    variant: 109,
    tuple: 110
  }

  @names Map.new(@ids, fn {name, id} -> {id, name} end)

  @spec id(atom()) :: id()
  def id(name), do: Map.fetch!(@ids, name)

  @spec name(id()) :: atom() | nil
  def name(id), do: Map.get(@names, id)

  @spec new(atom(), map() | nil) :: t()
  def new(name, type_info \\ nil) when is_atom(name) do
    %__MODULE__{id: id(name), name: name, type_info: type_info}
  end

  @doc """
  Returns DuckDB's `JSON` type, a VARCHAR alias, for appending JSON text.

  `:json` sends strings as JSON text as they are; `:variant` encodes every
  value, so strings become JSON strings.
  """
  @spec json(:json | :variant) :: t()
  def json(encoding) when encoding in [:json, :variant],
    do: new(:varchar, %{type: 1, alias: "JSON", encoding: encoding})

  @spec decimal_info(pos_integer(), non_neg_integer()) :: map()
  def decimal_info(width, scale), do: %{type: 2, width: width, scale: scale}

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = type) do
    [
      field(100, uleb128(type.id)),
      encode_type_info(type.type_info),
      end_object()
    ]
  end

  @spec decode(binary()) :: Reader.read_result(t())
  def decode(binary) do
    with {:ok, type, rest} <- decode_type(binary, %__MODULE__{}),
         :ok <- expect_type_id(type),
         :ok <- expect_type_info(type) do
      {:ok, type, rest}
    end
  end

  @sql_names %{
    sqlnull: "\"NULL\"",
    timestamp_sec: "TIMESTAMP_S",
    timestamp_ms: "TIMESTAMP_MS",
    timestamp_ns: "TIMESTAMP_NS",
    timestamp_tz: "TIMESTAMPTZ",
    timestamp_tz_ns: "TIMESTAMPTZ_NS",
    time_tz: "TIMETZ"
  }

  @doc """
  Renders a logical type as DuckDB SQL, for casts and type prototypes.
  """
  @spec to_sql(t()) :: iodata()
  def to_sql(%__MODULE__{name: :decimal, type_info: %{width: width, scale: scale}}),
    do: ["DECIMAL(", Integer.to_string(width), ", ", Integer.to_string(scale), ")"]

  def to_sql(%__MODULE__{name: :list} = type), do: [to_sql(child_type(type)), "[]"]

  def to_sql(%__MODULE__{name: :array} = type),
    do: [to_sql(child_type(type)), "[", Integer.to_string(array_size(type)), "]"]

  def to_sql(%__MODULE__{name: :map} = type) do
    [key, value] = type |> child_type() |> struct_children()
    ["MAP(", to_sql(key.type), ", ", to_sql(value.type), ")"]
  end

  def to_sql(%__MODULE__{name: :struct} = type) do
    fields =
      type
      |> struct_children()
      |> Enum.map(&[QuackDB.Type.quote_identifier(&1.name), " ", to_sql(&1.type)])
      |> Enum.intersperse(", ")

    ["STRUCT(", fields, ")"]
  end

  def to_sql(%__MODULE__{name: :enum, type_info: %{values: values}}) do
    ["ENUM(", values |> Enum.map(&QuackDB.SQL.literal!/1) |> Enum.intersperse(", "), ")"]
  end

  def to_sql(%__MODULE__{type_info: %{alias: alias_name}}) when is_binary(alias_name),
    do: alias_name

  def to_sql(%__MODULE__{name: name}) when is_map_key(@sql_names, name),
    do: Map.fetch!(@sql_names, name)

  def to_sql(%__MODULE__{name: name}) when is_atom(name) and name != nil,
    do: name |> Atom.to_string() |> String.upcase()

  def to_sql(type) do
    raise Error.new(:unsupported_type, "cannot render #{inspect(type)} as SQL", source: :client)
  end

  @doc """
  Returns whether decoded values of this type can hold binaries: strings,
  blobs, ENUM labels, or nested values containing them.
  """
  @spec holds_binaries?(t()) :: boolean()
  def holds_binaries?(%__MODULE__{name: name}) when name in [:enum, :variant], do: true

  def holds_binaries?(%__MODULE__{type_info: %{child_type: child}}), do: holds_binaries?(child)

  def holds_binaries?(%__MODULE__{type_info: %{children: children}}),
    do: Enum.any?(children, &holds_binaries?(&1.type))

  def holds_binaries?(%__MODULE__{} = type), do: physical_type(type) == :varchar

  @doc """
  Returns the physical storage type of a logical type, raising for types
  QuackDB cannot encode or decode, such as UNION.
  """
  @spec physical_type(t()) :: atom()
  def physical_type(type) do
    case fetch_physical_type(type) do
      {:ok, physical_type} -> physical_type
      {:error, error} -> raise error
    end
  end

  @doc "Returns the physical storage type of a logical type, or an `:unsupported_type` error."
  @spec fetch_physical_type(t()) :: {:ok, atom()} | {:error, Error.t()}
  def fetch_physical_type(type) do
    case physical_type_of(type) do
      nil -> error(:unsupported_type, "unsupported logical type #{inspect(type)}")
      physical_type -> {:ok, physical_type}
    end
  end

  defp physical_type_of(%__MODULE__{name: :boolean}), do: :bool
  defp physical_type_of(%__MODULE__{name: :tinyint}), do: :int8
  defp physical_type_of(%__MODULE__{name: :utinyint}), do: :uint8
  defp physical_type_of(%__MODULE__{name: :smallint}), do: :int16
  defp physical_type_of(%__MODULE__{name: :usmallint}), do: :uint16

  defp physical_type_of(%__MODULE__{name: name}) when name in [:sqlnull, :date, :integer],
    do: :int32

  defp physical_type_of(%__MODULE__{name: :uinteger}), do: :uint32

  defp physical_type_of(%__MODULE__{name: name}) when name in [:bigint | @int64_temporal],
    do: :int64

  defp physical_type_of(%__MODULE__{name: :ubigint}), do: :uint64
  defp physical_type_of(%__MODULE__{name: :float}), do: :float
  defp physical_type_of(%__MODULE__{name: :double}), do: :double

  defp physical_type_of(%__MODULE__{name: name})
       when name in [:varchar, :char, :blob, :bit, :bignum, :geometry], do: :varchar

  defp physical_type_of(%__MODULE__{name: :hugeint}), do: :int128
  defp physical_type_of(%__MODULE__{name: :uhugeint}), do: :uint128
  defp physical_type_of(%__MODULE__{name: :uuid}), do: :int128
  defp physical_type_of(%__MODULE__{name: :interval}), do: :interval

  defp physical_type_of(%__MODULE__{name: name}) when name in [:struct, :tuple, :variant],
    do: :struct

  defp physical_type_of(%__MODULE__{name: name}) when name in [:list, :map], do: :list
  defp physical_type_of(%__MODULE__{name: :array}), do: :array

  defp physical_type_of(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 4,
    do: :int16

  defp physical_type_of(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 9,
    do: :int32

  defp physical_type_of(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 18,
    do: :int64

  defp physical_type_of(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 38,
    do: :int128

  defp physical_type_of(%__MODULE__{name: :enum, type_info: %{values: values}}) do
    cond do
      Enum.count_until(values, 0xFF + 1) <= 0xFF -> :uint8
      Enum.count_until(values, 0xFFFF + 1) <= 0xFFFF -> :uint16
      true -> :uint32
    end
  end

  defp physical_type_of(%__MODULE__{name: :enum}), do: :uint32

  defp physical_type_of(_type), do: nil

  @spec fixed_size(atom()) :: pos_integer()
  def fixed_size(type) when type in [:bool, :int8, :uint8], do: 1
  def fixed_size(type) when type in [:int16, :uint16], do: 2
  def fixed_size(type) when type in [:int32, :uint32, :float], do: 4
  def fixed_size(type) when type in [:int64, :uint64, :double], do: 8
  def fixed_size(type) when type in [:interval, :int128, :uint128], do: 16

  @spec fixed_size?(atom()) :: boolean()
  def fixed_size?(type),
    do:
      type in [
        :bool,
        :int8,
        :uint8,
        :int16,
        :uint16,
        :int32,
        :uint32,
        :int64,
        :uint64,
        :float,
        :double,
        :interval,
        :int128,
        :uint128
      ]

  @spec child_type(t()) :: t()
  def child_type(%__MODULE__{type_info: %{child_type: child_type}}), do: child_type

  def child_type(type) do
    raise Error.new(
            :missing_child_type,
            "logical type #{inspect(type.name)} does not have child metadata",
            source: :protocol
          )
  end

  @spec struct_children(t()) :: [%{name: String.t(), type: t()}]
  def struct_children(%__MODULE__{type_info: %{children: children}}), do: children
  def struct_children(%__MODULE__{name: name}) when name in [:union, :variant], do: []

  def struct_children(type) do
    raise Error.new(
            :missing_struct_children,
            "logical type #{inspect(type.name)} does not have struct children metadata",
            source: :protocol
          )
  end

  @spec array_size(t()) :: non_neg_integer()
  def array_size(%__MODULE__{type_info: %{size: size}}), do: size

  def array_size(type) do
    raise Error.new(
            :missing_array_size,
            "logical type #{inspect(type.name)} does not have array size metadata",
            source: :protocol
          )
  end

  defp encode_type_info(nil), do: []

  defp encode_type_info(info) when is_map(info) do
    field(
      101,
      nullable(info, &encode_type_info_body/1)
    )
  end

  defp encode_type_info_body(%{type: type} = info) do
    [
      field(100, uleb128(type)),
      encode_type_info_alias(info),
      encode_type_info_fields(info),
      end_object()
    ]
  end

  defp encode_type_info_alias(%{alias: alias_name}) when is_binary(alias_name),
    do: field(101, string(alias_name))

  defp encode_type_info_alias(_info), do: []

  defp encode_type_info_fields(%{type: 2, width: width, scale: scale}) do
    [
      field(200, uleb128(width)),
      field(201, uleb128(scale))
    ]
  end

  defp encode_type_info_fields(%{type: 3} = info) do
    field(
      200,
      string(Map.get(info, :collation, ""))
    )
  end

  defp encode_type_info_fields(%{type: 4, child_type: child_type}) do
    field(200, encode(child_type))
  end

  defp encode_type_info_fields(%{type: 9, child_type: child_type, size: size}) do
    [
      field(200, encode(child_type)),
      field(201, uleb128(size))
    ]
  end

  defp encode_type_info_fields(%{type: 5, children: children}) do
    field(
      200,
      list(children, &encode_child_type/1)
    )
  end

  defp encode_type_info_fields(%{type: 6, values: values}) do
    [
      field(200, uleb128(length(values))),
      field(
        201,
        list(values, &string/1)
      )
    ]
  end

  defp encode_type_info_fields(%{type: 12, definition: definition}) do
    field(
      200,
      [
        field(100, string(definition)),
        end_object()
      ]
    )
  end

  defp encode_type_info_fields(%{type: type}) when type in [0, 1], do: []

  defp encode_type_info_fields(info) do
    raise Error.new(
            :unsupported_type_info,
            "encoding logical type metadata #{inspect(info)} is not supported",
            source: :protocol
          )
  end

  defp encode_child_type(%{name: name, type: type}) do
    [
      field(0, string(to_string(name))),
      field(1, encode(type)),
      end_object()
    ]
  end

  defp decode_type(binary, type),
    do:
      Reader.read_object(
        binary,
        type,
        &type_field/3,
        {:unknown_logical_type_field, "logical type"}
      )

  defp type_field(100, binary, type) do
    with {:ok, id, rest} <- Reader.read_uleb128(binary),
         do: {:ok, %{type | id: id, name: name(id)}, rest}
  end

  defp type_field(101, binary, type) do
    with {:ok, info, rest} <- Reader.read_nullable(binary, &decode_type_info/1),
         do: {:ok, %{type | type_info: info}, rest}
  end

  defp type_field(_field_id, _binary, _type), do: :unknown

  defp expect_type_id(%__MODULE__{id: id}) when is_integer(id), do: :ok

  defp expect_type_id(_type), do: error(:invalid_logical_type, "logical type is missing id field")

  defp expect_type_info(%__MODULE__{type_info: nil}), do: :ok
  defp expect_type_info(%__MODULE__{type_info: %{type: type}}) when is_integer(type), do: :ok

  defp expect_type_info(_type) do
    error(:invalid_logical_type_info, "logical type metadata is missing type field")
  end

  defp decode_type_info(binary) do
    with {:ok, info, rest} <-
           Reader.read_object(
             binary,
             %{},
             &type_info_field/3,
             {:unknown_type_info_field, "logical type metadata"}
           ),
         do: {:ok, default_type_info(info), rest}
  end

  defp type_info_field(100, binary, info),
    do: put_field(binary, info, :type, &Reader.read_uleb128/1)

  defp type_info_field(101, binary, info),
    do: put_field(binary, info, :alias, &Reader.read_string/1)

  defp type_info_field(200, binary, info), do: type_info_field_200(binary, info)
  defp type_info_field(201, binary, info), do: type_info_field_201(binary, info)
  defp type_info_field(_field_id, _binary, _info), do: :unknown

  defp put_field(binary, object, key, read) do
    with {:ok, value, rest} <- read.(binary), do: {:ok, Map.put(object, key, value), rest}
  end

  # DuckDB omits fields left at their defaults: a DECIMAL's zero scale, and
  # the empty child list of DuckDB 2.0's empty STRUCTs.
  defp default_type_info(%{type: 2} = info), do: Map.put_new(info, :scale, 0)
  defp default_type_info(%{type: 5} = info), do: Map.put_new(info, :children, [])
  defp default_type_info(info), do: info

  # Fields 200 and 201 hold the metadata of the type info's kind.
  defp type_info_field_200(binary, %{type: 2} = info),
    do: put_field(binary, info, :width, &Reader.read_uleb128/1)

  defp type_info_field_200(binary, %{type: 3} = info),
    do: put_field(binary, info, :collation, &Reader.read_string/1)

  defp type_info_field_200(binary, %{type: type} = info) when type in [4, 9],
    do: put_field(binary, info, :child_type, &decode/1)

  defp type_info_field_200(binary, %{type: 5} = info),
    do:
      put_field(
        binary,
        info,
        :children,
        &Reader.read_list(&1, fn rest -> decode_child_type(rest) end)
      )

  defp type_info_field_200(binary, %{type: 6} = info),
    do: put_field(binary, info, :values_count, &Reader.read_uleb128/1)

  defp type_info_field_200(binary, %{type: 13} = info),
    do: put_field(binary, info, :crs, &decode_crs/1)

  defp type_info_field_200(binary, info),
    do: put_field(binary, info, :value, &Reader.read_string/1)

  defp type_info_field_201(binary, %{type: 6} = info),
    do:
      put_field(
        binary,
        info,
        :values,
        &Reader.read_list(&1, fn rest -> Reader.read_string(rest) end)
      )

  defp type_info_field_201(binary, info),
    do: put_field(binary, info, field_201_name(info), &Reader.read_uleb128/1)

  # A GEOMETRY's coordinate reference system is an object holding its
  # definition, such as "OGC:CRS84"; DuckDB omits an empty one.
  defp decode_crs(binary),
    do:
      Reader.read_object(
        binary,
        nil,
        &crs_field/3,
        {:unknown_crs_field, "coordinate reference system"}
      )

  defp crs_field(100, binary, _definition), do: Reader.read_string(binary)
  defp crs_field(_field_id, _binary, _definition), do: :unknown

  defp decode_child_type(binary) do
    with {:ok, child, rest} <-
           Reader.read_object(
             binary,
             %{},
             &child_type_field/3,
             {:unknown_child_type_field, "child type"}
           ),
         :ok <- expect_child_type(child),
         do: {:ok, child, rest}
  end

  defp child_type_field(0, binary, child),
    do: put_field(binary, child, :name, &Reader.read_string/1)

  defp child_type_field(1, binary, child), do: put_field(binary, child, :type, &decode/1)
  defp child_type_field(_field_id, _binary, _child), do: :unknown

  defp expect_child_type(%{name: name, type: %__MODULE__{}}) when is_binary(name), do: :ok

  defp expect_child_type(child) do
    error(
      :invalid_child_type,
      "child type must include name and type fields, got #{inspect(child)}"
    )
  end

  defp field_201_name(%{type: 2}), do: :scale
  defp field_201_name(%{type: 6}), do: :values
  defp field_201_name(%{type: 9}), do: :size
  defp field_201_name(_info), do: :field_201

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

defimpl Inspect, for: QuackDB.Protocol.LogicalType do
  import Inspect.Algebra

  def inspect(type, opts) do
    fields = logical_type_fields(type)
    concat(QuackDB.Inspect.container("QuackDB.LogicalType", fields, opts))
  end

  defp logical_type_fields(%{name: :decimal, type_info: %{width: width, scale: scale}} = type) do
    [type: type.name, width: width, scale: scale]
  end

  defp logical_type_fields(%{name: name, type_info: %{child_type: child_type}})
       when name in [:list, :map] do
    [type: name, child: type_name(child_type)]
  end

  defp logical_type_fields(%{name: :array, type_info: %{child_type: child_type, size: size}}) do
    [type: :array, child: type_name(child_type), size: size]
  end

  defp logical_type_fields(%{name: :struct, type_info: %{children: children}}) do
    fields = Enum.map(children, fn %{name: name, type: type} -> {name, type_name(type)} end)
    [type: :struct, fields: fields]
  end

  defp logical_type_fields(type), do: [type: type.name || type.id]

  defp type_name(%{name: name}) when not is_nil(name), do: name
  defp type_name(%{id: id}), do: id
end

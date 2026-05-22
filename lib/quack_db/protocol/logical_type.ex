defmodule QuackDB.Protocol.LogicalType do
  @moduledoc false

  alias QuackDB.Error
  alias QuackDB.Protocol.Reader

  defstruct [:id, :name, :type_info]

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
    array: 108
  }

  @names Map.new(@ids, fn {name, id} -> {id, name} end)

  @spec id(atom()) :: id()
  def id(name), do: Map.fetch!(@ids, name)

  @spec name(id()) :: atom() | nil
  def name(id), do: Map.get(@names, id)

  @spec decode(binary()) :: Reader.read_result(t())
  def decode(binary), do: decode_type(binary, %__MODULE__{})

  @spec physical_type(t()) :: atom()
  def physical_type(%__MODULE__{name: :boolean}), do: :bool
  def physical_type(%__MODULE__{name: :tinyint}), do: :int8
  def physical_type(%__MODULE__{name: :utinyint}), do: :uint8
  def physical_type(%__MODULE__{name: :smallint}), do: :int16
  def physical_type(%__MODULE__{name: :usmallint}), do: :uint16
  def physical_type(%__MODULE__{name: name}) when name in [:sqlnull, :date, :integer], do: :int32
  def physical_type(%__MODULE__{name: :uinteger}), do: :uint32

  def physical_type(%__MODULE__{name: name})
      when name in [
             :bigint,
             :time,
             :time_ns,
             :timestamp,
             :timestamp_sec,
             :timestamp_ns,
             :timestamp_ms,
             :time_tz,
             :timestamp_tz
           ],
      do: :int64

  def physical_type(%__MODULE__{name: :ubigint}), do: :uint64
  def physical_type(%__MODULE__{name: :float}), do: :float
  def physical_type(%__MODULE__{name: :double}), do: :double

  def physical_type(%__MODULE__{name: name})
      when name in [:varchar, :char, :blob, :bit, :bignum, :geometry], do: :varchar

  def physical_type(%__MODULE__{name: :hugeint}), do: :int128
  def physical_type(%__MODULE__{name: :uhugeint}), do: :uint128
  def physical_type(%__MODULE__{name: :uuid}), do: :int128
  def physical_type(%__MODULE__{name: :interval}), do: :interval
  def physical_type(%__MODULE__{name: name}) when name in [:struct], do: :struct
  def physical_type(%__MODULE__{name: name}) when name in [:list, :map], do: :list
  def physical_type(%__MODULE__{name: :array}), do: :array

  def physical_type(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 4,
    do: :int16

  def physical_type(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 9,
    do: :int32

  def physical_type(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 18,
    do: :int64

  def physical_type(%__MODULE__{name: :decimal, type_info: %{width: width}}) when width <= 38,
    do: :int128

  def physical_type(%__MODULE__{name: :enum, type_info: %{values: values}})
      when length(values) <= 0xFF, do: :uint8

  def physical_type(%__MODULE__{name: :enum, type_info: %{values: values}})
      when length(values) <= 0xFFFF, do: :uint16

  def physical_type(%__MODULE__{name: :enum}), do: :uint32

  def physical_type(type),
    do:
      raise(
        Error.new(:unsupported_type, "unsupported logical type #{inspect(type)}",
          source: :protocol
        )
      )

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

  defp decode_type(binary, type) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, type, rest}

        field_id == 100 ->
          with {:ok, id, rest} <- Reader.read_uleb128(rest) do
            decode_type(rest, %{type | id: id, name: name(id)})
          end

        field_id == 101 ->
          with {:ok, info, rest} <- Reader.read_nullable(rest, &decode_type_info/1) do
            decode_type(rest, %{type | type_info: info})
          end

        true ->
          error(:unknown_logical_type_field, "unknown logical type field #{field_id}")
      end
    end
  end

  defp decode_type_info(binary), do: decode_type_info(binary, %{})

  defp decode_type_info(binary, info) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, info, rest}

        field_id == 100 ->
          with {:ok, type, rest} <- Reader.read_uleb128(rest) do
            decode_type_info(rest, Map.put(info, :type, type))
          end

        field_id == 101 ->
          with {:ok, alias_name, rest} <- Reader.read_string(rest) do
            decode_type_info(rest, Map.put(info, :alias, alias_name))
          end

        field_id == 200 ->
          decode_type_info_field_200(rest, info)

        field_id == 201 ->
          with {:ok, value, rest} <- Reader.read_uleb128(rest) do
            decode_type_info(rest, Map.put(info, field_201_name(info), value))
          end

        true ->
          error(:unknown_type_info_field, "unknown logical type metadata field #{field_id}")
      end
    end
  end

  defp decode_type_info_field_200(binary, %{type: 2} = info) do
    with {:ok, width, rest} <- Reader.read_uleb128(binary),
         do: decode_type_info(rest, Map.put(info, :width, width))
  end

  defp decode_type_info_field_200(binary, %{type: 3} = info) do
    with {:ok, collation, rest} <- Reader.read_string(binary),
         do: decode_type_info(rest, Map.put(info, :collation, collation))
  end

  defp decode_type_info_field_200(binary, %{type: type} = info) when type in [4, 9] do
    with {:ok, child_type, rest} <- decode(binary),
         do: decode_type_info(rest, Map.put(info, :child_type, child_type))
  end

  defp decode_type_info_field_200(binary, %{type: 5} = info) do
    with {:ok, children, rest} <- Reader.read_list(binary, &decode_child_type/1),
         do: decode_type_info(rest, Map.put(info, :children, children))
  end

  defp decode_type_info_field_200(binary, %{type: 6} = info) do
    with {:ok, count, rest} <- Reader.read_uleb128(binary),
         do: decode_type_info(rest, Map.put(info, :values_count, count))
  end

  defp decode_type_info_field_200(binary, info) do
    with {:ok, value, rest} <- Reader.read_string(binary),
         do: decode_type_info(rest, Map.put(info, :value, value))
  end

  defp decode_child_type(binary), do: decode_child_type(binary, %{})

  defp decode_child_type(binary, child) do
    with {:ok, field_id, rest} <- Reader.read_field_id(binary) do
      cond do
        field_id == QuackDB.Protocol.field_end() ->
          {:ok, child, rest}

        field_id == 0 ->
          with {:ok, name, rest} <- Reader.read_string(rest) do
            decode_child_type(rest, Map.put(child, :name, name))
          end

        field_id == 1 ->
          with {:ok, type, rest} <- decode(rest) do
            decode_child_type(rest, Map.put(child, :type, type))
          end

        true ->
          error(:unknown_child_type_field, "unknown child type field #{field_id}")
      end
    end
  end

  defp field_201_name(%{type: 2}), do: :scale
  defp field_201_name(%{type: 6}), do: :values
  defp field_201_name(%{type: 9}), do: :size
  defp field_201_name(_info), do: :field_201

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

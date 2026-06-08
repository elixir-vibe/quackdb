defmodule QuackDB.Protocol.Writer do
  @moduledoc """
  Binary writer helpers for Quack protocol encoding.
  """

  import Bitwise

  @spec field(non_neg_integer(), iodata()) :: iodata()
  def field(field_id, value) when field_id in 0..0xFFFE do
    [<<field_id::little-unsigned-16>>, value]
  end

  @spec end_object() :: <<_::16>>
  def end_object, do: <<QuackDB.Protocol.field_end()::little-unsigned-16>>

  @spec bool(boolean()) :: <<_::8>>
  def bool(false), do: <<0>>
  def bool(true), do: <<1>>

  @spec uleb128(non_neg_integer()) :: iodata()
  def uleb128(value) when is_integer(value) and value >= 0 do
    Varint.LEB128.encode(value)
  end

  @spec sleb128(integer()) :: iodata()
  def sleb128(value) when is_integer(value) do
    Varint.SLEB128.encode(value)
  end

  @spec string(String.t()) :: iodata()
  def string(value) when is_binary(value) do
    blob(value)
  end

  @spec blob(binary()) :: iodata()
  def blob(value) when is_binary(value) do
    [uleb128(byte_size(value)), value]
  end

  @spec list([value], (value -> iodata())) :: iodata() when value: term()
  def list(values, write_element) when is_list(values) and is_function(write_element, 1) do
    list(values, length(values), write_element)
  end

  @spec list([value], non_neg_integer(), (value -> iodata())) :: iodata() when value: term()
  def list(values, count, write_element)
      when is_list(values) and is_integer(count) and count >= 0 and is_function(write_element, 1) do
    [uleb128(count), Enum.map(values, write_element)]
  end

  @spec nullable(value | nil, (value -> iodata())) :: iodata() when value: term()
  def nullable(nil, _write_value), do: bool(false)

  def nullable(value, write_value) when is_function(write_value, 1) do
    [bool(true), write_value.(value)]
  end

  @spec optional_index(non_neg_integer() | nil) :: iodata()
  def optional_index(nil), do: uleb128(QuackDB.Protocol.optional_index_invalid())
  def optional_index(value), do: uleb128(value)

  @spec hugeint(integer()) :: iodata()
  def hugeint(value) when is_integer(value) do
    {upper, lower} = div_rem_floor(value, 1 <<< 64)
    [sleb128(upper), uleb128(lower)]
  end

  defp div_rem_floor(value, divisor) do
    quotient = div(value, divisor)
    remainder = rem(value, divisor)
    quotient = if value < 0 and remainder != 0, do: quotient - 1, else: quotient
    {quotient, value - quotient * divisor}
  end
end

defmodule QuackDB.Protocol.Writer do
  @moduledoc false

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
    do_uleb128(value, [])
  end

  @spec sleb128(integer()) :: iodata()
  def sleb128(value) when is_integer(value) do
    do_sleb128(value, [])
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
    [uleb128(length(values)), Enum.map(values, write_element)]
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

  defp do_uleb128(value, acc) when value < 0x80 do
    Enum.reverse([<<value>> | acc])
  end

  defp do_uleb128(value, acc) do
    byte = (value &&& 0x7F) ||| 0x80
    do_uleb128(value >>> 7, [<<byte>> | acc])
  end

  defp do_sleb128(value, acc) do
    byte = value &&& 0x7F
    next = value >>> 7
    sign_set? = (byte &&& 0x40) != 0
    done? = (next == 0 and not sign_set?) or (next == -1 and sign_set?)
    byte = if done?, do: byte, else: byte ||| 0x80
    acc = [<<byte>> | acc]

    if done? do
      Enum.reverse(acc)
    else
      do_sleb128(next, acc)
    end
  end

  defp div_rem_floor(value, divisor) do
    quotient = div(value, divisor)
    remainder = rem(value, divisor)
    quotient = if value < 0 and remainder != 0, do: quotient - 1, else: quotient
    {quotient, value - quotient * divisor}
  end
end

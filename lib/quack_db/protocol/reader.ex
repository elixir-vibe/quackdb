defmodule QuackDB.Protocol.Reader do
  @moduledoc false

  import Bitwise

  alias QuackDB.Error

  @type read_result(value) :: {:ok, value, binary()} | {:error, Error.t()}

  @spec read_field_id(binary()) :: read_result(non_neg_integer())
  def read_field_id(<<field_id::little-unsigned-16, rest::binary>>) do
    {:ok, field_id, rest}
  end

  def read_field_id(_binary) do
    error(:truncated_field_id, "expected a 16-bit field id")
  end

  @spec read_bool(binary()) :: read_result(boolean())
  def read_bool(<<0, rest::binary>>), do: {:ok, false, rest}
  def read_bool(<<1, rest::binary>>), do: {:ok, true, rest}

  def read_bool(<<_value, _rest::binary>>),
    do: error(:invalid_bool, "expected boolean byte 0 or 1")

  def read_bool(<<>>), do: error(:truncated_bool, "expected a boolean byte")

  @spec read_uleb128(binary()) :: read_result(non_neg_integer())
  def read_uleb128(binary), do: read_uleb128(binary, 0, 0)

  @spec read_sleb128(binary()) :: read_result(integer())
  def read_sleb128(binary), do: read_sleb128(binary, 0, 0)

  @spec read_string(binary()) :: read_result(String.t())
  def read_string(binary) do
    with {:ok, bytes, rest} <- read_blob(binary) do
      if String.valid?(bytes) do
        {:ok, bytes, rest}
      else
        error(:invalid_string, "expected valid UTF-8 string")
      end
    end
  end

  @spec read_blob(binary()) :: read_result(binary())
  def read_blob(binary) do
    with {:ok, size, rest} <- read_uleb128(binary),
         {:ok, blob, rest} <- take(rest, size) do
      {:ok, blob, rest}
    end
  end

  @spec read_list(binary(), (binary() -> read_result(value))) :: read_result([value])
        when value: term()
  def read_list(binary, read_element) when is_function(read_element, 1) do
    with {:ok, size, rest} <- read_uleb128(binary) do
      read_list_elements(rest, read_element, size, [])
    end
  end

  @spec read_nullable(binary(), (binary() -> read_result(value))) :: read_result(value | nil)
        when value: term()
  def read_nullable(binary, read_value) when is_function(read_value, 1) do
    with {:ok, present?, rest} <- read_bool(binary) do
      if present? do
        read_value.(rest)
      else
        {:ok, nil, rest}
      end
    end
  end

  @spec read_optional_index(binary()) :: read_result(non_neg_integer() | nil)
  def read_optional_index(binary) do
    with {:ok, value, rest} <- read_uleb128(binary) do
      if value == QuackDB.Protocol.optional_index_invalid() do
        {:ok, nil, rest}
      else
        {:ok, value, rest}
      end
    end
  end

  @spec read_hugeint(binary()) :: read_result(integer())
  def read_hugeint(binary) do
    with {:ok, upper, rest} <- read_sleb128(binary),
         {:ok, lower, rest} <- read_uleb128(rest) do
      {:ok, upper * (1 <<< 64) + lower, rest}
    end
  end

  @spec take(binary(), non_neg_integer()) :: read_result(binary())
  def take(binary, size) when byte_size(binary) >= size do
    <<value::binary-size(size), rest::binary>> = binary
    {:ok, value, rest}
  end

  def take(_binary, _size) do
    error(:truncated_binary, "binary ended before the expected number of bytes")
  end

  defp read_uleb128(<<byte, rest::binary>>, shift, value) do
    value = value ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      read_uleb128(rest, shift + 7, value)
    end
  end

  defp read_uleb128(<<>>, _shift, _value) do
    error(:truncated_uleb128, "unterminated unsigned LEB128 integer")
  end

  defp read_sleb128(<<byte, rest::binary>>, shift, value) do
    value = value ||| (byte &&& 0x7F) <<< shift
    shift = shift + 7

    if (byte &&& 0x80) == 0 do
      value = if (byte &&& 0x40) != 0, do: value - (1 <<< shift), else: value
      {:ok, value, rest}
    else
      read_sleb128(rest, shift, value)
    end
  end

  defp read_sleb128(<<>>, _shift, _value) do
    error(:truncated_sleb128, "unterminated signed LEB128 integer")
  end

  defp read_list_elements(rest, _read_element, 0, elements) do
    {:ok, Enum.reverse(elements), rest}
  end

  defp read_list_elements(binary, read_element, remaining, elements) do
    with {:ok, element, rest} <- read_element.(binary) do
      read_list_elements(rest, read_element, remaining - 1, [element | elements])
    end
  end

  defp error(code, message) do
    {:error, Error.new(code, message, source: :protocol)}
  end
end

defmodule QuackDB.ProtocolAssertions do
  @moduledoc false

  import ExUnit.Assertions

  def assert_same_binary(actual, expected) when is_binary(actual) and is_binary(expected) do
    assert actual == expected, binary_diff_message(actual, expected)
  end

  defp binary_diff_message(actual, expected) do
    mismatch = first_mismatch(actual, expected)

    """

    binary fixtures differ

    actual bytes:   #{byte_size(actual)}
    expected bytes: #{byte_size(expected)}
    first mismatch: #{inspect(mismatch)}

    actual:
    #{preview(actual, mismatch)}

    expected:
    #{preview(expected, mismatch)}
    """
  end

  defp first_mismatch(actual, expected) do
    limit = min(byte_size(actual), byte_size(expected))

    mismatch =
      if limit == 0 do
        nil
      else
        Enum.find(0..(limit - 1)//1, fn index ->
          :binary.at(actual, index) != :binary.at(expected, index)
        end)
      end

    mismatch || if byte_size(actual) == byte_size(expected), do: nil, else: limit
  end

  defp preview(binary, nil), do: preview(binary, 0)

  defp preview(binary, index) do
    start = max(index - 16, 0)
    size = min(byte_size(binary) - start, 48)

    binary
    |> binary_part(start, size)
    |> Base.encode16(case: :lower)
  end
end

defmodule QuackDB.TimeWithTimeZone do
  @moduledoc """
  DuckDB `TIME WITH TIME ZONE` value.

  DuckDB stores `TIME WITH TIME ZONE` as microseconds since midnight packed with
  a timezone offset in seconds. This struct exposes the decoded `Time` and UTC
  offset while preserving conversion to and from DuckDB's packed integer.
  """

  import Bitwise

  defstruct [:time, :utc_offset]

  @offset_basis 57_599
  @offset_mask 0xFF_FFFF

  @type t :: %__MODULE__{time: Time.t(), utc_offset: integer()}

  @doc "Builds a `TIME WITH TIME ZONE` value from time and UTC offset seconds."
  @spec new(Time.t(), integer()) :: t()
  def new(%Time{} = time, utc_offset) when is_integer(utc_offset) do
    %__MODULE__{time: time, utc_offset: utc_offset}
  end

  @doc "Decodes DuckDB's packed `TIME WITH TIME ZONE` integer."
  @spec from_bits(integer()) :: t()
  def from_bits(bits) when is_integer(bits) do
    micros = bits >>> 24
    encoded_offset = bits &&& @offset_mask

    new(Time.add(~T[00:00:00], micros, :microsecond), @offset_basis - encoded_offset)
  end

  @doc "Encodes the value into DuckDB's packed `TIME WITH TIME ZONE` integer."
  @spec to_bits(t()) :: integer()
  def to_bits(%__MODULE__{time: %Time{} = time, utc_offset: utc_offset}) do
    micros = Time.diff(time, ~T[00:00:00], :microsecond)
    encoded_offset = @offset_basis - utc_offset

    micros <<< 24 ||| encoded_offset
  end

  @doc "Formats the value as an ISO-like time with numeric UTC offset."
  @spec to_iso8601(t()) :: String.t()
  def to_iso8601(%__MODULE__{} = value) do
    value.time
    |> Time.to_iso8601()
    |> Kernel.<>(offset_to_string(value.utc_offset))
  end

  defp offset_to_string(offset) do
    sign = if offset < 0, do: "-", else: "+"
    offset = abs(offset)
    hours = div(offset, 3600)
    minutes = div(rem(offset, 3600), 60)

    sign <> pad2(hours) <> ":" <> pad2(minutes)
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end

if Code.ensure_loaded?(Inspect) do
  defimpl Inspect, for: QuackDB.TimeWithTimeZone do
    import Inspect.Algebra

    def inspect(value, _opts) do
      concat([
        string("#QuackDB.TimeWithTimeZone<"),
        string(QuackDB.TimeWithTimeZone.to_iso8601(value)),
        string(">")
      ])
    end
  end
end

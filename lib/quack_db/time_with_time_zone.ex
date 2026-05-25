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
end

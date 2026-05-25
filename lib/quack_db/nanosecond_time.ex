defmodule QuackDB.NanosecondTime do
  @moduledoc """
  DuckDB `TIME_NS` value stored as nanoseconds since midnight.

  Elixir's `Time` type stores microseconds, so this struct preserves DuckDB's
  nanosecond precision while still offering conversion to a truncated `Time`.
  """

  defstruct [:nanoseconds]

  @day_nanoseconds 86_400_000_000_000

  @type t :: %__MODULE__{nanoseconds: integer()}

  @doc "Builds a `TIME_NS` value from nanoseconds since midnight."
  @spec new(integer()) :: t()
  def new(nanoseconds) when is_integer(nanoseconds) do
    %__MODULE__{nanoseconds: nanoseconds}
  end

  @doc "Builds a `TIME_NS` value from an Elixir `Time`."
  @spec from_time(Time.t()) :: t()
  def from_time(%Time{} = time) do
    new(Time.diff(time, ~T[00:00:00], :nanosecond))
  end

  @doc "Converts to an Elixir `Time`, truncating sub-microsecond precision."
  @spec to_time(t()) :: Time.t()
  def to_time(%__MODULE__{nanoseconds: nanoseconds}) do
    ~T[00:00:00]
    |> Time.add(div(nanoseconds, 1_000), :microsecond)
    |> Map.put(:microsecond, {rem(div(nanoseconds, 1_000), 1_000_000), 6})
  end

  @doc "Returns true when the value is in DuckDB's time-of-day range."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{nanoseconds: nanoseconds}) do
    nanoseconds in 0..(@day_nanoseconds - 1)
  end
end

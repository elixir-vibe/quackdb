defmodule QuackDB.NanosecondTimestamp do
  @moduledoc """
  DuckDB `TIMESTAMP_NS` value stored as nanoseconds since the Unix epoch.

  Elixir's `NaiveDateTime` type stores microseconds, so this struct preserves
  DuckDB's nanosecond precision while offering conversion to a truncated
  `NaiveDateTime`.
  """

  defstruct [:nanoseconds]

  @type t :: %__MODULE__{nanoseconds: integer()}

  @doc "Builds a `TIMESTAMP_NS` value from nanoseconds since the Unix epoch."
  @spec new(integer()) :: t()
  def new(nanoseconds) when is_integer(nanoseconds) do
    %__MODULE__{nanoseconds: nanoseconds}
  end

  @doc "Builds a `TIMESTAMP_NS` value from an Elixir `NaiveDateTime`."
  @spec from_naive_datetime(NaiveDateTime.t()) :: t()
  def from_naive_datetime(%NaiveDateTime{} = value) do
    new(NaiveDateTime.diff(value, ~N[1970-01-01 00:00:00], :nanosecond))
  end

  @doc "Converts to an Elixir `NaiveDateTime`, truncating sub-microsecond precision."
  @spec to_naive_datetime(t()) :: NaiveDateTime.t()
  def to_naive_datetime(%__MODULE__{nanoseconds: nanoseconds}) do
    NaiveDateTime.add(~N[1970-01-01 00:00:00], div(nanoseconds, 1_000), :microsecond)
  end
end

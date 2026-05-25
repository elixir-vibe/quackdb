defmodule QuackDB.Interval do
  @moduledoc """
  DuckDB interval value preserving month, day, and microsecond components.

  DuckDB stores intervals as three independent components instead of a single
  duration because months and days do not have fixed microsecond lengths.
  """

  defstruct months: 0, days: 0, microseconds: 0

  @type t :: %__MODULE__{months: integer(), days: integer(), microseconds: integer()}

  @doc "Builds a DuckDB interval value."
  @spec new(integer(), integer(), integer()) :: t()
  def new(months \\ 0, days \\ 0, microseconds \\ 0)
      when is_integer(months) and is_integer(days) and is_integer(microseconds) do
    %__MODULE__{months: months, days: days, microseconds: microseconds}
  end
end

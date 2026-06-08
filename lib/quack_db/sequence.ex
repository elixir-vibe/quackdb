defmodule QuackDB.Sequence do
  @moduledoc """
  Helpers for DuckDB sequences.

  Native append writes full column vectors and does not evaluate column defaults.
  Use `next_values/4` to allocate sequence-backed IDs before appending rows
  with explicit primary keys.
  """

  @doc """
  Returns `count` values from a DuckDB sequence.

      ids = QuackDB.Sequence.next_values(conn, "fragments_id_seq", 3)
      #=> [1, 2, 3]

  The sequence name is encoded as a SQL string literal for `nextval/1`; callers
  should pass the actual DuckDB sequence name, not raw SQL.
  """
  @spec next_values(DBConnection.conn(), atom() | String.t(), non_neg_integer(), Keyword.t()) :: [
          integer()
        ]
  def next_values(connection, sequence_name, count, options \\ [])

  def next_values(connection, sequence_name, count, options)
      when (is_atom(sequence_name) or is_binary(sequence_name)) and is_integer(count) and
             count >= 0 do
    statement = [
      "SELECT nextval(",
      QuackDB.SQL.literal!(to_string(sequence_name)),
      ") AS value FROM range(",
      Integer.to_string(count),
      ")"
    ]

    connection
    |> QuackDB.query!(statement, [], options)
    |> values_from_result()
  end

  def next_values(_connection, sequence_name, count, _options) do
    raise ArgumentError,
          "expected a sequence name atom/string and a non-negative count, got: #{inspect(sequence_name)}, #{inspect(count)}"
  end

  defp values_from_result(%QuackDB.Result{rows: rows}) when is_list(rows) do
    Enum.map(rows, fn [value] -> value end)
  end
end

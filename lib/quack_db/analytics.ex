defmodule QuackDB.Analytics do
  import QuackDB.SQL.Fragment, only: [table: 1]

  @moduledoc """
  Direct SQL helpers for DuckDB analytical statements.
  """

  @doc "Builds a DuckDB `SUMMARIZE` profiling query for a table, source, or `{:query, sql}` tuple."
  @spec summarize(String.t() | atom() | {:query, iodata()}) :: iodata()
  def summarize(source) when is_atom(source), do: summarize(Atom.to_string(source))

  def summarize(source) when is_binary(source) do
    ["SUMMARIZE SELECT * FROM ", table(source)]
  end

  def summarize({:query, query}) do
    ["SUMMARIZE ", query]
  end
end

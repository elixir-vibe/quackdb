defmodule QuackDB.Analytics do
  @moduledoc """
  Direct SQL helpers for DuckDB analytical statements.
  """

  @doc "Builds a DuckDB `SUMMARIZE SELECT * FROM ...` profiling query for a table or source."
  @spec summarize(String.t() | atom()) :: iodata()
  def summarize(source) when is_atom(source), do: summarize(Atom.to_string(source))

  def summarize(source) when is_binary(source) do
    ["SUMMARIZE SELECT * FROM ", QuackDB.Type.quote_identifier(source)]
  end

  @doc "Builds a DuckDB `SUMMARIZE` query around arbitrary SQL iodata."
  @spec summarize_query(iodata()) :: iodata()
  def summarize_query(query) do
    ["SUMMARIZE ", query]
  end
end

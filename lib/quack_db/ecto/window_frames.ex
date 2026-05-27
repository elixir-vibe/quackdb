if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.WindowFrames do
    @moduledoc """
    DuckDB window-frame helpers for Ecto queries.

    Ecto versions before the release containing
    [ecto#4730](https://github.com/elixir-ecto/ecto/pull/4730) only accept literal
    `fragment(...)` calls in a window `:frame` option. These helpers are ready for
    that Ecto release; until your project depends on it, use the generated SQL
    shape directly:

        frame: fragment("ROWS BETWEEN 6 PRECEDING AND CURRENT ROW")

    Once macro-expanded frames are available in your Ecto version, helpers can be
    used as:

        frame: rows_between({:preceding, 6}, :current_row)
        frame: range_between(:unbounded_preceding, {:following, 1})
    """

    @doc "Builds a `ROWS BETWEEN ... AND ...` window frame fragment."
    defmacro rows_between(start_bound, end_bound) do
      frame_fragment("ROWS", start_bound, end_bound)
    end

    @doc "Builds a `RANGE BETWEEN ... AND ...` window frame fragment."
    defmacro range_between(start_bound, end_bound) do
      frame_fragment("RANGE", start_bound, end_bound)
    end

    @doc "Builds a `GROUPS BETWEEN ... AND ...` window frame fragment."
    defmacro groups_between(start_bound, end_bound) do
      frame_fragment("GROUPS", start_bound, end_bound)
    end

    defp frame_fragment(unit, start_bound, end_bound) do
      sql = [unit, " BETWEEN ", frame_bound!(start_bound), " AND ", frame_bound!(end_bound)]
      sql = IO.iodata_to_binary(sql)

      quote do
        fragment(unquote(sql))
      end
    end

    defp frame_bound!(:unbounded_preceding), do: "UNBOUNDED PRECEDING"
    defp frame_bound!(:unbounded_following), do: "UNBOUNDED FOLLOWING"
    defp frame_bound!(:current_row), do: "CURRENT ROW"

    defp frame_bound!({:preceding, count}) when is_integer(count) and count >= 0,
      do: [Integer.to_string(count), " PRECEDING"]

    defp frame_bound!({:following, count}) when is_integer(count) and count >= 0,
      do: [Integer.to_string(count), " FOLLOWING"]

    defp frame_bound!(bound) do
      raise ArgumentError,
            "unsupported window frame bound #{inspect(bound)}; expected :unbounded_preceding, " <>
              ":unbounded_following, :current_row, {:preceding, non_neg_integer}, or " <>
              "{:following, non_neg_integer}"
    end
  end
end

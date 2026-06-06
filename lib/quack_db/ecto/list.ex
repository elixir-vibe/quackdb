if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.List do
    @moduledoc """
    DuckDB LIST/ARRAY expression helpers for Ecto queries.

    The macros map directly to DuckDB list functions and are useful for querying
    `LIST` columns or Ecto `{:array, type}` fields backed by DuckDB lists.
    """

    @doc "Builds `len(list)`. Named to avoid `Kernel.length/1` import ambiguity."
    defmacro list_length(list) do
      quote do
        fragment("len(?)", unquote(list))
      end
    end

    @doc "Builds `list_extract(list, index)`. DuckDB list indexes are 1-based."
    defmacro extract(list, index) do
      quote do
        fragment("list_extract(?, ?)", unquote(list), unquote(index))
      end
    end

    @doc "Builds `list_slice(list, begin, end)`."
    defmacro slice(list, begin_index, end_index) do
      quote do
        fragment("list_slice(?, ?, ?)", unquote(list), unquote(begin_index), unquote(end_index))
      end
    end

    @doc "Builds `list_slice(list, begin, end, step)`."
    defmacro slice(list, begin_index, end_index, step) do
      quote do
        fragment(
          "list_slice(?, ?, ?, ?)",
          unquote(list),
          unquote(begin_index),
          unquote(end_index),
          unquote(step)
        )
      end
    end

    @doc "Builds `list_sort(list)`."
    defmacro sort(list) do
      quote do
        fragment("list_sort(?)", unquote(list))
      end
    end

    @doc "Builds `list_reverse_sort(list)`."
    defmacro reverse_sort(list) do
      quote do
        fragment("list_reverse_sort(?)", unquote(list))
      end
    end

    @doc "Builds `list_distinct(list)`."
    defmacro distinct(list) do
      quote do
        fragment("list_distinct(?)", unquote(list))
      end
    end

    @doc "Builds `list_unique(list)`."
    defmacro unique(list) do
      quote do
        fragment("list_unique(?)", unquote(list))
      end
    end

    @doc "Builds `list_position(list, value)`."
    defmacro position(list, value) do
      quote do
        fragment("list_position(?, ?)", unquote(list), unquote(value))
      end
    end

    @doc "Builds `list_contains(list, value)`."
    defmacro contains(list, value) do
      quote do
        fragment("list_contains(?, ?)", unquote(list), unquote(value))
      end
    end

    @doc "Alias for `contains/2` that avoids shared `contains/2` import ambiguity."
    defmacro contains_list(list, value) do
      quote do
        fragment("list_contains(?, ?)", unquote(list), unquote(value))
      end
    end

    @doc "Builds `list_has_any(left, right)`."
    defmacro has_any(left, right) do
      quote do
        fragment("list_has_any(?, ?)", unquote(left), unquote(right))
      end
    end

    @doc "Builds `list_has_all(left, right)`."
    defmacro has_all(left, right) do
      quote do
        fragment("list_has_all(?, ?)", unquote(left), unquote(right))
      end
    end

    @doc "Builds `list_intersect(left, right)`. Named to avoid Ecto `intersect/2` import ambiguity."
    defmacro intersect_list(left, right) do
      quote do
        fragment("list_intersect(?, ?)", unquote(left), unquote(right))
      end
    end

    @doc "Builds `list_concat(left, right)`."
    defmacro concat(left, right) do
      quote do
        fragment("list_concat(?, ?)", unquote(left), unquote(right))
      end
    end

    @doc "Builds `unnest(list)`."
    defmacro unnest(list) do
      quote do
        fragment("unnest(?)", unquote(list))
      end
    end
  end
end

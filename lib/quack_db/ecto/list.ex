if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.List do
    @moduledoc """
    DuckDB LIST/ARRAY expression helpers for Ecto queries.

    The macros map directly to DuckDB list functions and are useful for querying
    `LIST` columns or Ecto `{:array, type}` fields backed by DuckDB lists.
    """

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

    @doc "Builds `unnest(list)`."
    defmacro unnest(list) do
      quote do
        fragment("unnest(?)", unquote(list))
      end
    end
  end
end

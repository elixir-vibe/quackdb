if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Map do
    @moduledoc """
    DuckDB MAP expression helpers for Ecto queries.

    Natural names are available when importing this module directly. With
    `use QuackDB.Ecto`, ambiguous names such as `contains/2`, `extract/2`,
    `values/1`, and `concat/2` are excluded; use the explicit aliases instead.
    """

    @doc "Builds `cardinality(map)`."
    defmacro cardinality(map) do
      quote do
        fragment("cardinality(?)", unquote(map))
      end
    end

    @doc "Builds `cardinality(map)`."
    defmacro map_cardinality(map) do
      quote do
        fragment("cardinality(?)", unquote(map))
      end
    end

    @doc "Builds `map_keys(map)`."
    defmacro keys(map) do
      quote do
        fragment("map_keys(?)", unquote(map))
      end
    end

    @doc "Builds `map_keys(map)`."
    defmacro map_keys(map) do
      quote do
        fragment("map_keys(?)", unquote(map))
      end
    end

    @doc "Builds `map_values(map)`."
    defmacro values(map) do
      quote do
        fragment("map_values(?)", unquote(map))
      end
    end

    @doc "Builds `map_values(map)`."
    defmacro map_values(map) do
      quote do
        fragment("map_values(?)", unquote(map))
      end
    end

    @doc "Builds `map_entries(map)`."
    defmacro entries(map) do
      quote do
        fragment("map_entries(?)", unquote(map))
      end
    end

    @doc "Builds `map_entries(map)`."
    defmacro map_entries(map) do
      quote do
        fragment("map_entries(?)", unquote(map))
      end
    end

    @doc "Builds `map_contains(map, key)`."
    defmacro contains(map, key) do
      quote do
        fragment("map_contains(?, ?)", unquote(map), unquote(key))
      end
    end

    @doc "Builds `map_contains(map, key)`."
    defmacro contains_map(map, key) do
      quote do
        fragment("map_contains(?, ?)", unquote(map), unquote(key))
      end
    end

    @doc "Builds `map_contains_entry(map, key, value)`."
    defmacro contains_entry(map, key, value) do
      quote do
        fragment("map_contains_entry(?, ?, ?)", unquote(map), unquote(key), unquote(value))
      end
    end

    @doc "Builds `map_contains_entry(map, key, value)`."
    defmacro contains_map_entry(map, key, value) do
      quote do
        fragment("map_contains_entry(?, ?, ?)", unquote(map), unquote(key), unquote(value))
      end
    end

    @doc "Builds `map_contains_value(map, value)`."
    defmacro contains_value(map, value) do
      quote do
        fragment("map_contains_value(?, ?)", unquote(map), unquote(value))
      end
    end

    @doc "Builds `map_contains_value(map, value)`."
    defmacro contains_map_value(map, value) do
      quote do
        fragment("map_contains_value(?, ?)", unquote(map), unquote(value))
      end
    end

    @doc "Builds `map_extract(map, key)`."
    defmacro extract(map, key) do
      quote do
        fragment("map_extract(?, ?)", unquote(map), unquote(key))
      end
    end

    @doc "Builds `map_extract(map, key)`."
    defmacro map_extract(map, key) do
      quote do
        fragment("map_extract(?, ?)", unquote(map), unquote(key))
      end
    end

    @doc "Builds `map_extract_value(map, key)`."
    defmacro extract_value(map, key) do
      quote do
        fragment("map_extract_value(?, ?)", unquote(map), unquote(key))
      end
    end

    @doc "Builds `map_extract_value(map, key)`."
    defmacro map_extract_value(map, key) do
      quote do
        fragment("map_extract_value(?, ?)", unquote(map), unquote(key))
      end
    end

    @doc "Builds `map_concat(left, right)`."
    defmacro concat(left, right) do
      quote do
        fragment("map_concat(?, ?)", unquote(left), unquote(right))
      end
    end

    @doc "Builds `map_concat(left, right)`."
    defmacro map_concat(left, right) do
      quote do
        fragment("map_concat(?, ?)", unquote(left), unquote(right))
      end
    end
  end
end

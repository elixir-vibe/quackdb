if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Struct do
    @moduledoc """
    DuckDB STRUCT expression helpers for Ecto queries.

    Natural names are available when importing this module directly. With
    `use QuackDB.Ecto`, ambiguous names such as `contains/2`, `extract/2`,
    `values/1`, `position/2`, and `concat/2` are excluded; use the explicit
    aliases instead.
    """

    @doc "Builds `struct_extract(struct, field_or_index)`."
    defmacro extract(struct, field_or_index) do
      quote do
        fragment("struct_extract(?, ?)", unquote(struct), unquote(field_or_index))
      end
    end

    @doc "Builds `struct_extract(struct, field_or_index)`."
    defmacro struct_extract(struct, field_or_index) do
      quote do
        fragment("struct_extract(?, ?)", unquote(struct), unquote(field_or_index))
      end
    end

    @doc "Builds `struct_extract_at(struct, index)`."
    defmacro extract_at(struct, index) do
      quote do
        fragment("struct_extract_at(?, ?)", unquote(struct), unquote(index))
      end
    end

    @doc "Builds `struct_extract_at(struct, index)`."
    defmacro struct_extract_at(struct, index) do
      quote do
        fragment("struct_extract_at(?, ?)", unquote(struct), unquote(index))
      end
    end

    @doc "Builds `struct_contains(struct, value)`."
    defmacro contains(struct, value) do
      quote do
        fragment("struct_contains(?, ?)", unquote(struct), unquote(value))
      end
    end

    @doc "Builds `struct_contains(struct, value)`."
    defmacro contains_struct(struct, value) do
      quote do
        fragment("struct_contains(?, ?)", unquote(struct), unquote(value))
      end
    end

    @doc "Builds `struct_position(struct, value)`."
    defmacro position(struct, value) do
      quote do
        fragment("struct_position(?, ?)", unquote(struct), unquote(value))
      end
    end

    @doc "Builds `struct_position(struct, value)`."
    defmacro struct_position(struct, value) do
      quote do
        fragment("struct_position(?, ?)", unquote(struct), unquote(value))
      end
    end

    @doc "Builds `struct_values(struct)`."
    defmacro values(struct) do
      quote do
        fragment("struct_values(?)", unquote(struct))
      end
    end

    @doc "Builds `struct_values(struct)`."
    defmacro struct_values(struct) do
      quote do
        fragment("struct_values(?)", unquote(struct))
      end
    end

    @doc "Builds `struct_concat(left, right)`."
    defmacro concat(left, right) do
      quote do
        fragment("struct_concat(?, ?)", unquote(left), unquote(right))
      end
    end

    @doc "Builds `struct_concat(left, right)`."
    defmacro struct_concat(left, right) do
      quote do
        fragment("struct_concat(?, ?)", unquote(left), unquote(right))
      end
    end
  end
end

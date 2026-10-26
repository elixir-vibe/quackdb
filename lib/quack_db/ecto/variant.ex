if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Variant do
    @moduledoc """
    DuckDB 2.0 `VARIANT` expression helpers for Ecto queries.

    VARIANT columns decode to Elixir terms: objects become maps with string
    keys, arrays become lists, and scalars decode like the matching column type.
    These helpers inspect and extract inside a VARIANT on the server:

        import Ecto.Query
        import QuackDB.Ecto.Variant

        from event in "events",
          where: variant_type(event.payload) == "OBJECT",
          select: %{
            kind: variant_extract_string(event.payload, "kind"),
            first_tag: variant_extract(event.payload, [:tags, 1]),
            keys: variant_keys(event.payload)
          }

    A key is a field name; an integer extracts from an array, counting from 1.
    A list such as `[:tags, 1]` extracts one step at a time.
    """

    @doc """
    Builds `variant_extract(variant, key)`, which returns a VARIANT. Pass a list
    to extract along a path.
    """
    defmacro variant_extract(variant, path) when is_list(path) do
      Enum.reduce(path, variant, fn key, acc -> extract(acc, key) end)
    end

    defmacro variant_extract(variant, key), do: extract(variant, key)

    @doc "Builds `variant_extract_string(variant, key)`, the field rendered as text."
    defmacro variant_extract_string(variant, key) do
      quote do
        fragment("variant_extract_string(?, ?)", unquote(variant), unquote(key(key)))
      end
    end

    @doc """
    Builds `variant_type(variant)`, the VARIANT type name such as `"OBJECT"`,
    `"ARRAY"`, or `"INT64"`, or `variant_type(variant, key)` for a field.
    """
    defmacro variant_type(variant) do
      quote do
        fragment("variant_type(?)", unquote(variant))
      end
    end

    defmacro variant_type(variant, key) do
      quote do
        fragment("variant_type(?, ?)", unquote(variant), unquote(key(key)))
      end
    end

    @doc "Builds `variant_typeof(variant)`, the DuckDB type the value would have unwrapped."
    defmacro variant_typeof(variant) do
      quote do
        fragment("variant_typeof(?)", unquote(variant))
      end
    end

    @doc "Builds `variant_keys(variant)`, or `variant_keys(variant, key)` for a nested object."
    defmacro variant_keys(variant) do
      quote do
        fragment("variant_keys(?)", unquote(variant))
      end
    end

    defmacro variant_keys(variant, key) do
      quote do
        fragment("variant_keys(?, ?)", unquote(variant), unquote(key(key)))
      end
    end

    @doc "Builds `variant_array_length(variant)`, or `variant_array_length(variant, key)`."
    defmacro variant_array_length(variant) do
      quote do
        fragment("variant_array_length(?)", unquote(variant))
      end
    end

    defmacro variant_array_length(variant, key) do
      quote do
        fragment("variant_array_length(?, ?)", unquote(variant), unquote(key(key)))
      end
    end

    @doc "Builds `variant_contains(haystack, needle)`; the needle is cast to VARIANT."
    defmacro variant_contains(haystack, needle) do
      quote do
        fragment("variant_contains(?, CAST(? AS VARIANT))", unquote(haystack), unquote(needle))
      end
    end

    defp extract(variant, index) when is_integer(index) and index > 0 do
      quote do
        fragment("variant_extract(?, CAST(? AS UINTEGER))", unquote(variant), unquote(index))
      end
    end

    defp extract(_variant, index) when is_integer(index) do
      raise ArgumentError, "VARIANT array indexes count from 1, got: #{index}"
    end

    defp extract(variant, key) do
      quote do
        fragment("variant_extract(?, ?)", unquote(variant), unquote(key(key)))
      end
    end

    defp key(key) when is_atom(key) and key not in [nil, true, false], do: Atom.to_string(key)
    defp key(key), do: key
  end
end

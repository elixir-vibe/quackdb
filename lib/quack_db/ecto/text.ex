if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Text do
    @moduledoc """
    DuckDB text-expression helpers for Ecto queries.

        import Ecto.Query
        import QuackDB.Ecto.Text

        from event in "events",
          where: contains(event.name, "duck") and starts_with(event.kind, "bird"),
          select: %{
            second_part: split_part(event.name, "-", 2),
            tags: string_split(event.tags, ",")
          }

    `contains_text/2` emits the same DuckDB `contains(?, ?)` call as
    `contains/2`. It is useful with `use QuackDB.Ecto`, where shared
    `contains/2` may dispatch between text and spatial predicates.
    """

    @text_helpers [
      %{name: :contains, sql: "contains", arities: [2]},
      %{name: :contains_text, sql: "contains", arities: [2]},
      %{name: :starts_with, arities: [2]},
      %{name: :ends_with, arities: [2]},
      %{name: :prefix, arities: [2]},
      %{name: :suffix, arities: [2]},
      %{name: :split_part, arities: [3]},
      %{name: :string_split, arities: [2]},
      %{name: :string_split_regex, arities: [2, 3]}
    ]

    @doc """
    Literal text containment with an explicit case-sensitivity option.

        contains(event.name, ^search, case_sensitive: false)

    With `case_sensitive: false`, both operands are lowercased by DuckDB before
    matching. This is not full Unicode case folding. Wildcards remain literal;
    an empty search matches and NULL operands produce NULL. Options must be a
    literal keyword list with a boolean `:case_sensitive` value.
    """
    defmacro contains(value, search, options) do
      sql =
        case options do
          [case_sensitive: false] -> "contains(lower(?), lower(?))"
          [case_sensitive: true] -> "contains(?, ?)"
          _ -> raise ArgumentError, "contains/3 expects case_sensitive: true or false"
        end

      text_fragment(sql, [value, search])
    end

    @doc false
    def __text_helpers__, do: @text_helpers

    for %{name: name, arities: arities} = helper <- @text_helpers, arity <- arities do
      sql = Map.get(helper, :sql, Atom.to_string(name))
      arguments = Macro.generate_arguments(arity, __MODULE__)

      fragment_sql =
        IO.iodata_to_binary([
          sql,
          "(",
          Enum.map_join(1..arity, ", ", fn _ -> "?" end),
          ")"
        ])

      defmacro unquote(name)(unquote_splicing(arguments)) do
        text_fragment(unquote(fragment_sql), [unquote_splicing(arguments)])
      end
    end

    defp text_fragment(sql, arguments) do
      quote do
        fragment(unquote(sql), unquote_splicing(arguments))
      end
    end
  end
end

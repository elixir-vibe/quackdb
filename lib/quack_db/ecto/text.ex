if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Text do
    @moduledoc """
    DuckDB text-expression helpers for Ecto queries.
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

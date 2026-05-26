if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Conditionals do
    @moduledoc """
    Opt-in Elixir conditional syntax for Ecto analytical queries.

    Importing this module replaces Kernel's `if/2` in the caller, so it is not
    imported by `use QuackDB.Ecto` unless `conditionals: true` is passed.

        use QuackDB.Ecto, conditionals: true

        from event in "events",
          select: %{
            tier:
              if event.score >= 90 do
                "high"
              else
                "normal"
              end
          }

    The expression compiles to DuckDB `CASE WHEN ... THEN ... ELSE ... END`.
    """

    defmacro __using__(_options) do
      quote do
        import Kernel, except: [if: 2]
        import unquote(__MODULE__), only: [if: 2]
      end
    end

    defmacro if(condition, clauses) when is_list(clauses) do
      then_expression = Keyword.fetch!(clauses, :do)
      else_expression = Keyword.get(clauses, :else, nil)

      quote do
        fragment(
          "CASE WHEN ? THEN ? ELSE ? END",
          unquote(condition),
          unquote(then_expression),
          unquote(else_expression)
        )
      end
    end
  end
end

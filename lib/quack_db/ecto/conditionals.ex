if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Conditionals do
    @moduledoc """
    Conditional expression helpers for Ecto analytical queries.

    `case_when/1` keeps multi-branch SQL `CASE WHEN` expressions readable while
    preserving normal Ecto operators inside each condition:

        use QuackDB.Ecto

        from event in "events",
          select: %{
            tier:
              case_when do
                event.score >= 90 -> "high"
                event.score >= 50 -> "medium"
                true -> "low"
              end
          }

    The expression compiles to DuckDB `CASE WHEN ... THEN ... ELSE ... END`.
    """

    defmacro case_when(do: clauses) do
      clauses = List.wrap(clauses)
      {when_clauses, else_expression} = split_clauses!(clauses)

      sql =
        ["CASE ", Enum.map(when_clauses, fn _ -> "WHEN ? THEN ? " end), "ELSE ? END"]
        |> IO.iodata_to_binary()

      args =
        when_clauses
        |> Enum.flat_map(fn {condition, expression} -> [condition, expression] end)
        |> Kernel.++([else_expression])

      quote do
        fragment(unquote(sql), unquote_splicing(args))
      end
    end

    defp split_clauses!(clauses) do
      parsed = Enum.map(clauses, &parse_clause!/1)
      [last | rest_reversed] = Enum.reverse(parsed)

      case last do
        {:else, else_expression} -> {Enum.reverse(rest_reversed), else_expression}
        _other -> raise ArgumentError, "case_when requires a final true -> expression clause"
      end
    end

    defp parse_clause!({:->, _meta, [[true], expression]}), do: {:else, expression}
    defp parse_clause!({:->, _meta, [[condition], expression]}), do: {condition, expression}

    defp parse_clause!(other) do
      raise ArgumentError, "invalid case_when clause: #{Macro.to_string(other)}"
    end
  end
end

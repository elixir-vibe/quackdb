if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ecto.Adapters.QuackDB.Query do
    @moduledoc """
    Read-oriented Ecto query SQL generation for QuackDB.

    This module turns supported `Ecto.Query` ASTs into DuckDB SQL iodata.
    Unsupported analytical shapes raise explicit `QuackDB.Error` values so the
    adapter does not emit misleading SQL.
    """

    @spec all(Ecto.Query.t()) :: iodata()
    def all(%Ecto.Query{} = query) do
      assert_read_only_query!(query)

      [
        with_ctes(query.with_ctes),
        select(query.select, query.distinct),
        " FROM ",
        source(query.from, 0),
        joins(query.joins),
        wheres(query.wheres),
        group_bys(query.group_bys),
        havings(query.havings),
        windows(query.windows),
        order_bys(query.order_bys),
        limit(query.limit),
        offset(query.offset)
      ]
    end

    @spec update_all(Ecto.Query.t()) :: iodata()
    def update_all(%Ecto.Query{} = query) do
      assert_mutation_query!(query)

      [
        with_ctes(query.with_ctes),
        "UPDATE ",
        source(query.from, 0),
        " SET ",
        updates(query.updates),
        wheres(query.wheres)
      ]
    end

    @spec delete_all(Ecto.Query.t()) :: iodata()
    def delete_all(%Ecto.Query{} = query) do
      assert_mutation_query!(query)

      [
        with_ctes(query.with_ctes),
        "DELETE FROM ",
        source(query.from, 0),
        wheres(query.wheres)
      ]
    end

    defp assert_read_only_query!(%Ecto.Query{} = query) do
      cond do
        query.combinations != [] ->
          unsupported!(:combinations, "Ecto combinations are unsupported; use Repo.query/3")

        query.lock != nil ->
          unsupported!(:locks, "Ecto locks are unsupported; use Repo.query/3")

        true ->
          :ok
      end
    end

    defp assert_mutation_query!(%Ecto.Query{} = query) do
      cond do
        query.joins != [] ->
          unsupported!(
            :joins,
            "Ecto update_all/delete_all with joins is unsupported; use Repo.query/3"
          )

        query.group_bys != [] or query.havings != [] or query.windows != [] ->
          unsupported!(
            :mutation_query,
            "grouped Ecto update_all/delete_all is unsupported; use Repo.query/3"
          )

        query.order_bys != [] or query.limit != nil or query.offset != nil ->
          unsupported!(
            :mutation_query,
            "ordered or limited Ecto update_all/delete_all is unsupported; use Repo.query/3"
          )

        query.combinations != [] ->
          unsupported!(:combinations, "Ecto combinations are unsupported; use Repo.query/3")

        query.lock != nil ->
          unsupported!(:locks, "Ecto locks are unsupported; use Repo.query/3")

        true ->
          :ok
      end
    end

    defp with_ctes(nil), do: []

    defp with_ctes(%Ecto.Query.WithExpr{queries: queries, recursive: recursive}) do
      ctes =
        Enum.map(queries, fn
          {name, %{operation: :all}, %Ecto.Query{} = query} ->
            [quote_identifier(name), " AS (", all(query), ")"]

          {name, operation, %Ecto.Query{}} ->
            unsupported!(
              :cte,
              "unsupported Ecto CTE operation for #{name}: #{inspect(operation)}"
            )
        end)

      ["WITH ", recursive(recursive), Enum.intersperse(ctes, ", "), " "]
    end

    defp recursive(true), do: "RECURSIVE "
    defp recursive(false), do: []

    defp select(nil, distinct), do: ["SELECT ", distinct(distinct), "*"]

    defp select(%Ecto.Query.SelectExpr{expr: expr}, distinct) do
      ["SELECT ", distinct(distinct), select_expr(expr)]
    end

    defp distinct(nil), do: []
    defp distinct(%{expr: true}), do: "DISTINCT "

    defp distinct(%{expr: expressions}) when is_list(expressions) do
      expressions =
        expressions
        |> Enum.map(fn {_direction, expression} -> expr(expression) end)
        |> Enum.intersperse(", ")

      ["DISTINCT ON (", expressions, ") "]
    end

    defp distinct(%{expr: expression}), do: ["DISTINCT ON (", expr(expression), ") "]

    defp select_expr({:%{}, _meta, fields}) do
      fields
      |> Enum.map(fn {alias_name, expr} -> [expr(expr), " AS ", quote_identifier(alias_name)] end)
      |> Enum.intersperse(", ")
    end

    defp select_expr({:{}, _meta, fields}) do
      fields |> Enum.map(&expr/1) |> Enum.intersperse(", ")
    end

    defp select_expr(fields) when is_list(fields) do
      fields |> Enum.map(&expr/1) |> Enum.intersperse(", ")
    end

    defp select_expr(expr), do: expr(expr)

    defp source(%{source: {table, nil}}, index) when is_binary(table) do
      [source_name(table), " AS q", to_string(index)]
    end

    defp source(%{source: {table, schema}}, index)
         when is_binary(table) and is_atom(schema) do
      [source_name(table), " AS q", to_string(index)]
    end

    defp source(%{source: %Ecto.SubQuery{query: query}}, index) do
      ["(", all(query), ") AS q", to_string(index)]
    end

    defp source(%{source: {:fragment, _meta, parts}}, index) do
      [fragment(parts), " AS q", to_string(index)]
    end

    defp source(_from, _index) do
      unsupported!(
        :source,
        "only table, source helper, fragment, and subquery sources are supported in Ecto queries"
      )
    end

    defp source_name(table) do
      if QuackDB.Source.source?(table) do
        table
      else
        quote_identifier(table)
      end
    end

    defp joins([]), do: []

    defp joins(joins) do
      joins
      |> Enum.with_index(1)
      |> Enum.map(fn {join, index} ->
        [" ", join_qualifier(join.qual), " ", source(join, index), " ON ", expr(join.on.expr)]
      end)
    end

    defp join_qualifier(:inner), do: "INNER JOIN"
    defp join_qualifier(:left), do: "LEFT OUTER JOIN"
    defp join_qualifier(:right), do: "RIGHT OUTER JOIN"
    defp join_qualifier(:full), do: "FULL OUTER JOIN"
    defp join_qualifier(:cross), do: "CROSS JOIN"

    defp join_qualifier(qualifier) do
      unsupported!(:join, "unsupported Ecto join qualifier: #{inspect(qualifier)}")
    end

    defp updates([]),
      do: unsupported!(:schema_updates, "Ecto update_all requires update expressions")

    defp updates(updates) do
      updates
      |> Enum.flat_map(&update_expr/1)
      |> Enum.intersperse(", ")
    end

    defp update_expr(%Ecto.Query.QueryExpr{expr: expressions}) do
      Enum.flat_map(expressions, fn
        {:set, fields} ->
          Enum.map(fields, fn {field, expression} ->
            [quote_identifier(field), " = ", expr(expression)]
          end)

        {:inc, fields} ->
          Enum.map(fields, fn {field, expression} ->
            quoted = quote_identifier(field)
            [quoted, " = ", quoted, " + ", expr(expression)]
          end)

        {operation, _fields} ->
          unsupported!(
            :schema_updates,
            "Ecto update operation #{inspect(operation)} is unsupported"
          )
      end)
    end

    defp wheres([]), do: []

    defp wheres(wheres) do
      expressions = Enum.map(wheres, fn %{expr: expression} -> expr(expression) end)
      [" WHERE ", Enum.intersperse(expressions, " AND ")]
    end

    defp group_bys([]), do: []

    defp group_bys(group_bys) do
      expressions =
        group_bys
        |> Enum.flat_map(& &1.expr)
        |> Enum.map(&expr/1)

      [" GROUP BY ", Enum.intersperse(expressions, ", ")]
    end

    defp havings([]), do: []

    defp havings(havings) do
      expressions = Enum.map(havings, fn %{expr: expression} -> expr(expression) end)
      [" HAVING ", Enum.intersperse(expressions, " AND ")]
    end

    defp windows([]), do: []

    defp windows(windows) do
      definitions =
        Enum.map(windows, fn {name, window} ->
          [quote_identifier(name), " AS (", window_expr(window.expr), ")"]
        end)

      [" WINDOW ", Enum.intersperse(definitions, ", ")]
    end

    defp window_expr(parts) do
      parts
      |> Enum.map(fn
        {:partition_by, expressions} ->
          ["PARTITION BY ", expressions |> Enum.map(&expr/1) |> Enum.intersperse(", ")]

        {:order_by, expressions} ->
          ["ORDER BY ", order_by_exprs(expressions)]
      end)
      |> Enum.intersperse(" ")
    end

    defp order_bys([]), do: []

    defp order_bys(order_bys) do
      expressions = order_bys |> Enum.flat_map(& &1.expr) |> order_by_exprs()
      [" ORDER BY ", expressions]
    end

    defp order_by_exprs(expressions) do
      expressions
      |> Enum.map(fn {direction, expression} ->
        [expr(expression), " ", order_direction(direction)]
      end)
      |> Enum.intersperse(", ")
    end

    defp limit(nil), do: []
    defp limit(%{expr: expression}), do: [" LIMIT ", expr(expression)]

    defp offset(nil), do: []
    defp offset(%{expr: expression}), do: [" OFFSET ", expr(expression)]

    defp expr({{:., _meta, [{:&, _binding_meta, [binding]}, field]}, _call_meta, []})
         when is_integer(binding) and is_atom(field) do
      ["q", to_string(binding), ".", quote_identifier(field)]
    end

    defp expr({aggregate, _meta, [expression]})
         when aggregate in [:count, :avg, :sum, :min, :max] do
      [aggregate |> Atom.to_string() |> String.upcase(), "(", expr(expression), ")"]
    end

    defp expr({:count, _meta, []}), do: "COUNT(*)"

    defp expr({window_function, _meta, []})
         when window_function in [:row_number, :rank, :dense_rank, :percent_rank, :cume_dist] do
      [window_function |> Atom.to_string() |> String.upcase(), "()"]
    end

    defp expr({:over, _meta, [expression, window]}) do
      [expr(expression), " OVER ", over_expr(window)]
    end

    defp expr({:filter, _meta, [aggregate, predicate]}) do
      [expr(aggregate), " FILTER (WHERE ", expr(predicate), ")"]
    end

    defp expr({:fragment, _meta, parts}), do: fragment(parts)

    defp expr({op, _meta, [left, right]}) when op in [:==, :!=, :>, :<, :>=, :<=] do
      ["(", expr(left), " ", operator(op), " ", expr(right), ")"]
    end

    defp expr({op, _meta, [left, right]}) when op in [:and, :or] do
      ["(", expr(left), " ", op |> Atom.to_string() |> String.upcase(), " ", expr(right), ")"]
    end

    defp expr({op, _meta, [left, right]}) when op in [:+, :-, :*, :/] do
      ["(", expr(left), " ", operator(op), " ", expr(right), ")"]
    end

    defp expr({:in, _meta, [left, right]}) do
      ["(", expr(left), " IN ", in_expr(right), ")"]
    end

    defp expr({:not, _meta, [{:is_nil, _is_nil_meta, [expression]}]}) do
      ["(", expr(expression), " IS NOT NULL)"]
    end

    defp expr({:not, _meta, [expression]}) do
      ["(NOT ", expr(expression), ")"]
    end

    defp expr({:like, _meta, [left, right]}) do
      ["(", expr(left), " LIKE ", expr(right), ")"]
    end

    defp expr({:is_nil, _meta, [expression]}) do
      ["(", expr(expression), " IS NULL)"]
    end

    defp expr({:^, _meta, [_index]}), do: "?"
    defp expr(%Ecto.Query.Tagged{value: value}), do: literal(value)
    defp expr(value) when is_binary(value), do: literal(value)
    defp expr(value) when is_integer(value) or is_float(value), do: to_string(value)
    defp expr(value) when is_boolean(value), do: if(value, do: "TRUE", else: "FALSE")
    defp expr(nil), do: "NULL"

    defp expr(other) do
      unsupported!(:expression, "unsupported Ecto query expression: #{inspect(other)}")
    end

    defp over_expr(window) when is_atom(window), do: quote_identifier(window)
    defp over_expr(window) when is_list(window), do: ["(", window_expr(window), ")"]

    defp fragment(parts) do
      Enum.map(parts, fn
        {:raw, value} -> value
        {:expr, expression} -> expr(expression)
      end)
    end

    defp in_expr(%Ecto.Query.Tagged{value: values}) when is_list(values), do: in_expr(values)

    defp in_expr(values) when is_list(values) do
      ["(", values |> Enum.map(&expr/1) |> Enum.intersperse(", "), ")"]
    end

    defp in_expr(expression), do: expr(expression)

    defp literal(value) when is_binary(value), do: ["'", String.replace(value, "'", "''"), "'"]
    defp literal(%Date{} = value), do: ["DATE '", Date.to_iso8601(value), "'"]

    defp literal(%NaiveDateTime{} = value),
      do: ["TIMESTAMP '", NaiveDateTime.to_iso8601(value), "'"]

    defp literal(%DateTime{} = value), do: ["TIMESTAMPTZ '", DateTime.to_iso8601(value), "'"]
    defp literal(%Decimal{} = value), do: Decimal.to_string(value)
    defp literal(value), do: expr(value)

    defp operator(:==), do: "="
    defp operator(:!=), do: "<>"
    defp operator(op), do: Atom.to_string(op)

    defp order_direction(:asc), do: "ASC"
    defp order_direction(:desc), do: "DESC"
    defp order_direction(:asc_nulls_last), do: "ASC NULLS LAST"
    defp order_direction(:asc_nulls_first), do: "ASC NULLS FIRST"
    defp order_direction(:desc_nulls_last), do: "DESC NULLS LAST"
    defp order_direction(:desc_nulls_first), do: "DESC NULLS FIRST"

    defp quote_identifier(value) do
      value = value |> to_string() |> String.replace("\"", "\"\"")
      ["\"", value, "\""]
    end

    defp unsupported!(feature, message) do
      raise QuackDB.Error.new(:ecto_feature_not_supported, message,
              source: :client,
              metadata: %{feature: feature}
            )
    end
  end
end
